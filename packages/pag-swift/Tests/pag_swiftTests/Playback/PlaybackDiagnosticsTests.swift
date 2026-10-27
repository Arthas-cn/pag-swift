import Foundation
import Testing
@testable import pag_swift

/// 验证 GPU 与实际呈现的权限、计时和报告边界；系统窗口证据另由集成测试提供。
struct PlaybackDiagnosticsTests {
    /// 暂停撤销旧播放帧的呈现许可；GPU 迟到后只补提冻结位置。
    @Test(.timeLimit(.minutes(1))) func pauseRejectsPlayingPresentation() async throws {
        let rig = PlaybackTestRig()
        var requests = rig.probe.requests.makeAsyncIterator()
        try await rig.controller.setComposition(PlaybackTestRig.composition())
        await rig.controller.updateTarget(.available)
        let first = try #require(await requests.next())
        try await rig.controller.play()
        await rig.controller.pause()
        #expect(first.gate.withPresentationPermission(for: first.token) { true } == nil)
        try await rig.probe.complete(first)
        let paused = try #require(await requests.next())
        #expect(!paused.isPlaying)
        try await rig.probe.complete(paused)
    }

    /// GPU 完成消费提交许可后，同代数下一帧不能抢走前帧的实际呈现资格。
    @Test func presentationOutlivesGPUCompletionButNotControlGeneration() throws {
        let gate = PlaybackSubmissionGate()
        let first = PlaybackRequestToken(documentID: nil, compositionRevision: 1,
            playbackEpoch: UUID(), targetEpoch: UUID(), requestID: UUID())
        gate.allow(first)
        #expect(gate.claimCompletion(first))
        #expect(gate.withPresentationPermission(for: first) { true } == true)
        let next = PlaybackRequestToken(documentID: nil, compositionRevision: 1,
            playbackEpoch: first.playbackEpoch, targetEpoch: first.targetEpoch, requestID: UUID())
        gate.allow(next)
        #expect(!gate.permits(first))
        #expect(gate.withPresentationPermission(for: first) { true } == true)
        gate.revoke()
        #expect(gate.withPresentationPermission(for: first) { true } == nil)
        let changed = PlaybackRequestToken(documentID: nil, compositionRevision: 1,
            playbackEpoch: UUID(), targetEpoch: first.targetEpoch, requestID: UUID())
        gate.allow(changed)
        #expect(gate.withPresentationPermission(for: first) { true } == nil)
    }

    /// 零呈现时间不激活跑马灯，正时间扣除首次等待；显示代数撤销后迟到回调不可生效。
    @Test func marqueeStartsAtActualPresentation() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        let slot = try #require(file.contentSlots.first)
        var composition = file.composition
        try await composition.apply(.text(String(repeating: "长文", count: 30),
            layout: .marquee(PAGMarqueeOptions(speed: 40, gap: 20))), forTag: slot.tag)
        let scene = try await PreparedScene.prepare(composition)
        let layer = try #require(composition.layers.first(where: { $0.kind == .text }))
        let clock = try #require(scene.marqueeClock)
        let mailbox = DisplayTargetMailbox()
        let epoch = try #require(mailbox.beginMutation())
        #expect(mailbox.finishMutation(epoch, configuration: DisplayTargetConfiguration(
            geometry: try DisplayGeometry(size: PAGSize(width: 100, height: 100), scale: 1),
            isMounted: true, isActive: true)))
        let token = PlaybackRequestToken(documentID: file.storage.identity, compositionRevision: 1,
            playbackEpoch: UUID(), targetEpoch: epoch, requestID: UUID())
        let gate = PlaybackSubmissionGate()
        gate.allow(token)
        let diagnostics = PlaybackDiagnosticSession(playerID: UUID(), document: file.storage.identity)
        let request = PlaybackFrameRequest(scene: scene, time: .zero, scaleMode: .aspectFit,
            token: token, gate: gate, endsPlayback: false, isPlaying: true,
            auxiliaryTime: PAGTime(microseconds: 1_000_000), diagnostics: diagnostics)
        let receipt = FramePresentationReceipt(request: request, mailbox: mailbox,
            placeholderIDs: [], marqueeIDs: [layer.id])
        diagnostics.record(.submitted, token: token)
        diagnostics.record(.gpuCompleted, token: token, seconds: 0.001)
        #expect(clock.elapsed(for: layer.id, at: PAGTime(microseconds: 2_000_000)) == .zero)
        receipt.presented(at: 0)
        try await waitForPresentationUpdate { diagnostics.snapshot.skippedPresentations == 1 }
        #expect(diagnostics.snapshot.presentedFrames == nil)
        #expect(diagnostics.snapshot.skippedPresentations == 1)
        #expect(gate.claimCompletion(token))
        receipt.presented(at: request.sampledHostTime + 0.2)
        try await waitForPresentationUpdate { diagnostics.snapshot.firstPresentationSeconds != nil }
        let elapsed = clock.elapsed(for: layer.id, at: PAGTime(microseconds: 2_000_000)).microseconds
        #expect(abs(elapsed - 800_000) <= 1)
        #expect(diagnostics.snapshot.firstPresentationSeconds != nil)
        _ = mailbox.beginMutation()
        receipt.presented(at: request.sampledHostTime + 0.4)
        try await waitForPresentationUpdate { diagnostics.snapshot.stalePresentedFrames == 1 }
        #expect(diagnostics.snapshot.stalePresentedFrames == 1)
        #expect(clock.elapsed(for: layer.id, at: PAGTime(microseconds: 2_000_000)).microseconds == elapsed)
    }

    /// 有界日志淘汰旧事件但不损失累计计数；不可用的 GPU 和呈现指标不能变成假零。
    @Test func boundedHistoryKeepsDistinctEvidence() throws {
        let session = PlaybackDiagnosticSession(playerID: UUID())
        for _ in 0..<200 { session.record(.submitted) }
        session.record(.gpuCompleted)
        session.record(.coalesced)
        session.record(.drawableUnavailable)
        let value = session.snapshot
        #expect(value.events.count == 128)
        #expect(value.submittedFrames == 200)
        #expect(value.gpuCompletedFrames == 1)
        #expect(value.presentedFrames == nil)
        #expect(value.totalGPUSeconds == nil)
        #expect(value.coalescedRequests == 1)
        #expect(value.drawableFailures == 1)
        let decoded = try JSONDecoder().decode(PAGPlaybackDiagnostics.self, from: JSONEncoder().encode(value))
        #expect(decoded.sessionID == value.sessionID)
    }
}
