import Testing
@testable import pag_swift

/// 透明清屏与内容帧共用的代数、排队和恢复合同；协议替身不证明GPU像素结果。
@Suite(.timeLimit(.minutes(1)))
struct PlaybackClearTests {
    /// 初始空播放器绑定可用目标会清屏一次，完成不产生presentedTime或非empty状态。
    @Test func emptyPlayerClearsNewTargetWithoutInventingTime() async throws {
        let rig = PlaybackTestRig()
        var requests = rig.probe.requests.makeAsyncIterator(), events = rig.events.makeAsyncIterator()
        await rig.controller.updateTarget(.available)
        let clear = try #require(await requests.next())
        #expect(clear.scene == nil && clear.token.documentID == nil && clear.time == .zero && !clear.endsPlayback)
        try await rig.probe.complete(clear)
        try await PlaybackTestRig.wait(for: .workFinished(clear.token.requestID, accepted: true), in: &events)
        let snapshot = await rig.controller.snapshot
        #expect(snapshot.state == .empty && snapshot.presentedTime == nil && snapshot.duration == nil)
        await rig.controller.setRepeatCount(4)
        #expect(await rig.probe.count == 1)
        await rig.controller.updateTarget(.available, geometryChanged: true)
        let resized = try #require(await requests.next())
        #expect(resized.scene == nil && resized.token.targetEpoch != clear.token.targetEpoch)
        try await rig.probe.complete(resized)
    }

    /// 隐藏时清空只记录意图，恢复时才提交最新clear，旧已呈现时间立即失效。
    @Test func hiddenClearWaitsForAvailableTarget() async throws {
        let rig = PlaybackTestRig()
        var requests = rig.probe.requests.makeAsyncIterator(), events = rig.events.makeAsyncIterator()
        try await rig.controller.setComposition(PlaybackTestRig.composition())
        await rig.controller.updateTarget(.available)
        let content = try #require(await requests.next())
        try await rig.probe.complete(content)
        try await PlaybackTestRig.wait(for: .workFinished(content.token.requestID, accepted: true), in: &events)
        await rig.controller.updateTarget(.unavailable)
        try await rig.controller.setComposition(nil)
        let empty = await rig.controller.snapshot
        #expect(empty.state == .empty && empty.revision == 2 && empty.presentedTime == nil)
        #expect(await rig.probe.count == 1)
        await rig.controller.updateTarget(.available)
        let clear = try #require(await requests.next())
        #expect(clear.scene == nil && clear.token.compositionRevision == 2)
        try await rig.probe.complete(clear)
        try await PlaybackTestRig.wait(for: .workFinished(clear.token.requestID, accepted: true), in: &events)
        #expect(await rig.controller.snapshot.presentedTime == nil)
    }

    /// 已开始的clear被新内容取代后只能结束自身工作，不能擦除新状态或发布零时间。
    @Test func newCompositionSupersedesLateClear() async throws {
        let rig = PlaybackTestRig()
        var requests = rig.probe.requests.makeAsyncIterator(), events = rig.events.makeAsyncIterator()
        await rig.controller.updateTarget(.available)
        let old = try #require(await requests.next())
        try await rig.controller.setComposition(PlaybackTestRig.composition())
        #expect(!old.gate.permits(old.token))
        try await rig.probe.complete(old)
        try await PlaybackTestRig.wait(for: .workFinished(old.token.requestID, accepted: false), in: &events)
        let content = try #require(await requests.next())
        #expect(content.scene != nil && content.token.documentID != nil && content.token.compositionRevision == 1)
        try await rig.probe.complete(content)
        try await PlaybackTestRig.wait(for: .workFinished(content.token.requestID, accepted: true), in: &events)
        let snapshot = await rig.controller.snapshot
        #expect(snapshot.state == .ready && snapshot.presentedTime == .zero)
    }

    /// 新clear撤销尚未完成的内容请求，内容迟到完成不能把empty倒写为已经显示旧时间。
    @Test func clearingRejectsLateContentCompletion() async throws {
        let rig = PlaybackTestRig()
        var requests = rig.probe.requests.makeAsyncIterator(), events = rig.events.makeAsyncIterator()
        try await rig.controller.setComposition(PlaybackTestRig.composition())
        await rig.controller.updateTarget(.available)
        let old = try #require(await requests.next())
        try await rig.controller.setComposition(nil)
        #expect(!old.gate.permits(old.token))
        try await rig.probe.complete(old)
        try await PlaybackTestRig.wait(for: .workFinished(old.token.requestID, accepted: false), in: &events)
        let clear = try #require(await requests.next())
        #expect(clear.scene == nil)
        try await rig.probe.complete(clear)
        try await PlaybackTestRig.wait(for: .workFinished(clear.token.requestID, accepted: true), in: &events)
        let snapshot = await rig.controller.snapshot
        #expect(snapshot.state == .empty && snapshot.presentedTime == nil && snapshot.completedIterations == 0)
    }

    /// drawable暂不可用不丢清屏意图，下一可用代数重试且仍没有公开播放时间。
    @Test func unavailableClearRetriesOnNewTargetState() async throws {
        let rig = PlaybackTestRig()
        var requests = rig.probe.requests.makeAsyncIterator(), events = rig.events.makeAsyncIterator()
        await rig.controller.updateTarget(.available)
        let first = try #require(await requests.next())
        await rig.probe.resolve(first, result: .success(.targetUnavailable))
        try await PlaybackTestRig.wait(for: .workFinished(first.token.requestID, accepted: true), in: &events)
        await rig.controller.updateTarget(.available)
        let retry = try #require(await requests.next())
        #expect(retry.scene == nil && retry.token.targetEpoch != first.token.targetEpoch)
        try await rig.probe.complete(retry)
        try await PlaybackTestRig.wait(for: .workFinished(retry.token.requestID, accepted: true), in: &events)
        #expect(await rig.controller.snapshot.presentedTime == nil)
    }

    /// 清屏协议错报内容时间必须失败；重新nil安装可以清除失败并重试正确清屏。
    @Test func invalidClearCompletionFailsAndNewInstallRecovers() async throws {
        let rig = PlaybackTestRig()
        var requests = rig.probe.requests.makeAsyncIterator(), events = rig.events.makeAsyncIterator()
        await rig.controller.updateTarget(.available)
        let first = try #require(await requests.next())
        await rig.probe.resolve(first, result: .success(.submitted(.zero)))
        try await PlaybackTestRig.wait(for: .workFinished(first.token.requestID, accepted: true), in: &events)
        #expect(await rig.controller.snapshot.failure == .renderingFailure("unexpectedContentCompletion"))
        try await rig.controller.setComposition(nil)
        let retry = try #require(await requests.next())
        try await rig.probe.complete(retry)
        try await PlaybackTestRig.wait(for: .workFinished(retry.token.requestID, accepted: true), in: &events)
        let snapshot = await rig.controller.snapshot
        #expect(snapshot.failure == nil && snapshot.state == .empty && snapshot.presentedTime == nil)
    }
}
