import Foundation
import Testing
@testable import pag_swift

/// 真实控制 actor 的限流、播放终点与失败语义；协议替身不构成 GPU 画面验收。
@Suite(.timeLimit(.minutes(1)))
struct PlaybackControllerTests {
    /// 一个活动请求和最新待处理请求足够消化多个 tick；seek 同步撤销旧许可且拒绝迟到结果。
    @Test func coalescesTicksAndRejectsLateSeekCompletion() async throws {
        let rig = PlaybackTestRig()
        var requests = rig.probe.requests.makeAsyncIterator()
        var events = rig.events.makeAsyncIterator()
        try await rig.controller.setComposition(PlaybackTestRig.composition())
        await rig.controller.setRepeatCount(0)
        await rig.controller.updateTarget(.available)
        let first = try #require(await requests.next())
        try await rig.controller.play()
        for time: UInt64 in [100_000, 200_000, 300_000] {
            rig.clock.set(time)
            await rig.controller.tick(at: time)
        }
        #expect(await rig.probe.count == 1)
        #expect(await rig.controller.snapshot.position.microseconds == 300_000)
        try await rig.probe.complete(first)
        try await PlaybackTestRig.wait(for: .workFinished(first.token.requestID, accepted: true), in: &events)
        let second = try #require(await requests.next())
        #expect(second.time.microseconds == 300_000)
        #expect(await rig.controller.snapshot.presentedTime == .zero)
        try await rig.controller.seek(to: PAGTime(microseconds: 600_000))
        #expect(!second.gate.permits(second.token))
        try await rig.probe.complete(second)
        try await PlaybackTestRig.wait(for: .workFinished(second.token.requestID, accepted: false), in: &events)
        #expect(await rig.controller.snapshot.position.microseconds == 600_000)
        #expect(await rig.controller.snapshot.presentedTime == .zero)
        let latest = try #require(await requests.next())
        #expect(latest.time.microseconds == 600_000)
        #expect(latest.token.playbackEpoch != second.token.playbackEpoch)
        try await rig.probe.complete(latest)
        try await PlaybackTestRig.wait(for: .workFinished(latest.token.requestID, accepted: true), in: &events)
        #expect(await rig.probe.count == 3)
        let expected = try SceneTiming.root(at: latest.time, in: #require(latest.scene).composition.storage).representedTime
        #expect(await rig.controller.snapshot.presentedTime == expected)
    }

    /// 自动播放跨过有限终点后仍等末帧完成；隐藏撤销旧末帧，恢复后重新提交才 finished。
    @Test func terminalFrameMustSurviveTargetEpoch() async throws {
        let rig = PlaybackTestRig()
        let composition = try await PlaybackTestRig.composition()
        var requests = rig.probe.requests.makeAsyncIterator()
        var events = rig.events.makeAsyncIterator()
        try await rig.controller.setComposition(composition)
        await rig.controller.updateTarget(.available)
        let first = try #require(await requests.next())
        try await rig.controller.play()
        let end = UInt64(composition.duration.microseconds)
        rig.clock.set(end)
        await rig.controller.tick(at: end)
        try await rig.probe.complete(first)
        let terminal = try #require(await requests.next())
        #expect(terminal.endsPlayback)
        #expect(await rig.controller.snapshot.state == .playing)
        await rig.controller.updateTarget(.unavailable)
        try await rig.probe.complete(terminal)
        try await PlaybackTestRig.wait(for: .workFinished(terminal.token.requestID, accepted: false), in: &events)
        #expect(await rig.controller.snapshot.state == .suspended)
        rig.clock.set(end * 10)
        await rig.controller.updateTarget(.available)
        let resumed = try #require(await requests.next())
        #expect(resumed.time.microseconds == composition.duration.microseconds - 1)
        #expect(resumed.token.targetEpoch != terminal.token.targetEpoch)
        try await rig.probe.complete(resumed)
        try await PlaybackTestRig.wait(for: .workFinished(resumed.token.requestID, accepted: true), in: &events)
        let snapshot = await rig.controller.snapshot
        #expect(snapshot.state == .finished)
        #expect(snapshot.completedIterations == 1)
        #expect(snapshot.presentedTime != nil)
    }

    /// 主错误保留有效图像时间与请求位置；普通控制不能恢复，完整同文档替换才清除错误。
    @Test func failureIsPublishedAndReplacementRecoversAtomically() async throws {
        let rig = PlaybackTestRig()
        let composition = try await PlaybackTestRig.composition()
        var requests = rig.probe.requests.makeAsyncIterator()
        var events = rig.events.makeAsyncIterator()
        try await rig.controller.setComposition(composition)
        await rig.controller.updateTarget(.available)
        let first = try #require(await requests.next())
        try await rig.probe.complete(first)
        try await PlaybackTestRig.wait(for: .workFinished(first.token.requestID, accepted: true), in: &events)
        try await rig.controller.seek(to: PAGTime(microseconds: 1_000_000))
        let broken = try #require(await requests.next())
        let error = PAGError.renderingFailure("deviceLost")
        await rig.probe.resolve(broken, result: .failure(error))
        try await PlaybackTestRig.wait(for: .workFinished(broken.token.requestID, accepted: true), in: &events)
        #expect(await rig.controller.snapshot.state == .failed)
        #expect(await rig.controller.snapshot.failure == error)
        #expect(await rig.controller.snapshot.presentedTime == .zero)
        await #expect(throws: error) { try await rig.controller.play() }
        try await rig.controller.replaceComposition(composition)
        let recovered = try #require(await requests.next())
        #expect(recovered.time.microseconds == 1_000_000)
        #expect(recovered.token.compositionRevision == 2)
        #expect(await rig.controller.snapshot.state == .paused)
        #expect(await rig.controller.snapshot.failure == nil)
        #expect(await rig.controller.snapshot.presentedTime == nil)
        try await rig.probe.complete(recovered)
        try await PlaybackTestRig.wait(for: .workFinished(recovered.token.requestID, accepted: true), in: &events)
    }

    /// 缩放与 resize 都使旧许可失效；前者更换公开 revision，后者只更换目标代数。
    @Test func scaleAndResizeInvalidateDifferentGenerations() async throws {
        let rig = PlaybackTestRig()
        var requests = rig.probe.requests.makeAsyncIterator()
        var events = rig.events.makeAsyncIterator()
        try await rig.controller.setComposition(PlaybackTestRig.composition())
        await rig.controller.updateTarget(.available)
        let first = try #require(await requests.next())
        await rig.controller.setScaleMode(.aspectFill)
        await rig.controller.updateTarget(.available, geometryChanged: true)
        #expect(!first.gate.permits(first.token))
        try await rig.probe.complete(first)
        let next = try #require(await requests.next())
        #expect(next.scaleMode == .aspectFill)
        #expect(next.token.compositionRevision == first.token.compositionRevision + 1)
        #expect(next.token.targetEpoch != first.token.targetEpoch)
        try await rig.probe.complete(next)
        try await PlaybackTestRig.wait(for: .workFinished(next.token.requestID, accepted: true), in: &events)
    }

    /// 真实mailbox代数原样进入提交token；相同可用状态但新代数仍撤销旧工作。
    @Test func targetEpochComesFromActualDisplayTransaction() async throws {
        let rig = PlaybackTestRig()
        var requests = rig.probe.requests.makeAsyncIterator()
        var events = rig.events.makeAsyncIterator()
        try await rig.controller.setComposition(PlaybackTestRig.composition())
        let firstEpoch = UUID(), secondEpoch = UUID()
        await rig.controller.updateTarget(.available, epoch: firstEpoch)
        let first = try #require(await requests.next())
        #expect(first.token.targetEpoch == firstEpoch)
        await rig.controller.updateTarget(.available, epoch: firstEpoch)
        #expect(first.gate.permits(first.token))
        await rig.controller.updateTarget(.available, epoch: secondEpoch)
        #expect(!first.gate.permits(first.token))
        try await rig.probe.complete(first)
        let second = try #require(await requests.next())
        #expect(second.token.targetEpoch == secondEpoch)
        try await rig.probe.complete(second)
        try await PlaybackTestRig.wait(for: .workFinished(second.token.requestID, accepted: true), in: &events)
    }

    /// stop 与 rewind 在 actor 层也遵守暂停保留位置、回零清计数及无表面前置条件。
    @Test func controlsWorkWithoutPretendingToRender() async throws {
        let rig = PlaybackTestRig()
        await #expect(throws: PAGError.missingComposition) { try await rig.controller.play() }
        try await rig.controller.setComposition(PlaybackTestRig.composition())
        await #expect(throws: PAGError.missingSurface) { try await rig.controller.play() }
        try await rig.controller.seek(to: .end)
        let position = await rig.controller.snapshot.position
        await rig.controller.stop()
        #expect(await rig.controller.snapshot.state == .paused)
        #expect(await rig.controller.snapshot.position == position)
        try await rig.controller.rewind()
        #expect(await rig.controller.snapshot.position == .zero)
        try await rig.controller.setComposition(nil)
        #expect(await rig.controller.snapshot.state == .empty)
        #expect(await rig.probe.count == 0)
    }
}
