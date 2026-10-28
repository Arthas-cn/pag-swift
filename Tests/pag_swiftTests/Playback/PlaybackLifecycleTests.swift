import Testing
@testable import pag_swift

/// 显式等待、订阅和场景安装事务的取消/完成竞争，全部使用可控暂停点。
@Suite(.timeLimit(.minutes(1)))
struct PlaybackLifecycleTests {
    /// 显式 render 等有效量化提交；drawable 不可用只返回 targetUnavailable，不成为主错误。
    @Test func renderReturnsQuantizedCompletionAndUnavailable() async throws {
        let rig = PlaybackTestRig()
        var requests = rig.probe.requests.makeAsyncIterator()
        var events = rig.events.makeAsyncIterator()
        try await rig.controller.setComposition(PlaybackTestRig.composition())
        await rig.controller.updateTarget(.available)
        let first = try #require(await requests.next())
        try await rig.probe.complete(first)
        try await PlaybackTestRig.wait(for: .workFinished(first.token.requestID, accepted: true), in: &events)
        let render = Task { try await rig.controller.render(at: PAGTime(microseconds: 123_456)) }
        let explicit = try #require(await requests.next())
        #expect(await rig.controller.snapshot.state == .paused)
        #expect(await rig.controller.snapshot.position.microseconds == 123_456)
        let expected = try SceneTiming.root(at: explicit.time, in: #require(explicit.scene).composition.storage).representedTime
        try await rig.probe.complete(explicit)
        #expect(try await render.value == .submitted(time: expected, revision: 1))
        let unavailable = Task { try await rig.controller.render(at: PAGTime(microseconds: 1_000_000)) }
        let next = try #require(await requests.next())
        await rig.probe.resolve(next, result: .success(.targetUnavailable))
        #expect(try await unavailable.value == .targetUnavailable)
        #expect(await rig.controller.snapshot.failure == nil)
        #expect(await rig.controller.snapshot.presentedTime == expected)
        #expect(try await rig.controller.render(at: .zero) == .targetUnavailable)
    }

    /// 已开始 render 的调用者取消立即返回，不等待故意忽略取消的后台完成。
    @Test func activeRenderCancellationRejectsLateCompletion() async throws {
        let rig = PlaybackTestRig()
        var requests = rig.probe.requests.makeAsyncIterator()
        var events = rig.events.makeAsyncIterator()
        try await rig.controller.setComposition(PlaybackTestRig.composition())
        await rig.controller.updateTarget(.available)
        let first = try #require(await requests.next())
        try await rig.probe.complete(first)
        try await PlaybackTestRig.wait(for: .workFinished(first.token.requestID, accepted: true), in: &events)
        let render = Task { try await rig.controller.render(at: PAGTime(microseconds: 123_456)) }
        let explicit = try #require(await requests.next())
        render.cancel()
        await #expect(throws: CancellationError.self) { try await render.value }
        #expect(!explicit.gate.permits(explicit.token))
        try await rig.probe.complete(explicit)
        try await PlaybackTestRig.wait(for: .workFinished(explicit.token.requestID, accepted: false), in: &events)
        #expect(await rig.controller.snapshot.presentedTime == .zero)
        #expect(await rig.controller.snapshot.failure == nil)
        #expect(await rig.controller.snapshot.position.microseconds == 123_456)
    }

    /// render 还在待处理槽时取消，旧工作退出也不得重新给已取消请求安装提交许可。
    @Test func pendingRenderCancellationNeverStartsSubmission() async throws {
        let rig = PlaybackTestRig()
        var requests = rig.probe.requests.makeAsyncIterator()
        var events = rig.events.makeAsyncIterator()
        try await rig.controller.setComposition(PlaybackTestRig.composition())
        await rig.controller.updateTarget(.available)
        let first = try #require(await requests.next())
        var snapshots = await rig.controller.snapshots().makeAsyncIterator()
        let render = Task { try await rig.controller.render(at: PAGTime(microseconds: 123_456)) }
        while let snapshot = await snapshots.next() {
            if snapshot.position.microseconds == 123_456 { break }
        }
        render.cancel()
        await #expect(throws: CancellationError.self) { try await render.value }
        try await rig.probe.complete(first)
        try await PlaybackTestRig.wait(for: .workFinished(first.token.requestID, accepted: false), in: &events)
        try await rig.controller.seek(to: PAGTime(microseconds: 234_567))
        let next = try #require(await requests.next())
        #expect(next.time.microseconds == 234_567)
        #expect(await rig.probe.count == 2)
        try await rig.probe.complete(next)
        try await PlaybackTestRig.wait(for: .workFinished(next.token.requestID, accepted: true), in: &events)
    }

    /// 新 seek 取代显式 render 后等待立即取消；旧底层返回成功不能更新新请求位置。
    @Test func newControlSupersedesExplicitWaiter() async throws {
        let rig = PlaybackTestRig()
        var requests = rig.probe.requests.makeAsyncIterator()
        var events = rig.events.makeAsyncIterator()
        try await rig.controller.setComposition(PlaybackTestRig.composition())
        await rig.controller.updateTarget(.available)
        let first = try #require(await requests.next())
        try await rig.probe.complete(first)
        try await PlaybackTestRig.wait(for: .workFinished(first.token.requestID, accepted: true), in: &events)
        let render = Task { try await rig.controller.render(at: PAGTime(microseconds: 100_000)) }
        let explicit = try #require(await requests.next())
        try await rig.controller.seek(to: PAGTime(microseconds: 900_000))
        await #expect(throws: CancellationError.self) { try await render.value }
        try await rig.probe.complete(explicit)
        let next = try #require(await requests.next())
        #expect(next.time.microseconds == 900_000)
        #expect(await rig.controller.snapshot.presentedTime == .zero)
        try await rig.probe.complete(next)
        try await PlaybackTestRig.wait(for: .workFinished(next.token.requestID, accepted: true), in: &events)
    }

    /// 每个订阅先收到当前值，慢消费者只收到最新定位；取消移除对应 continuation。
    @Test func snapshotsKeepLatestAndRemoveCancelledConsumer() async throws {
        let rig = PlaybackTestRig()
        var events = rig.events.makeAsyncIterator()
        try await rig.controller.setComposition(PlaybackTestRig.composition())
        var values = await rig.controller.snapshots().makeAsyncIterator()
        let initial = try #require(await values.next())
        #expect(initial.state == .ready && initial.revision == 1)
        for time: Int64 in [100, 200, 300] { try await rig.controller.seek(to: PAGTime(microseconds: time)) }
        let latest = try #require(await values.next())
        #expect(latest.position.microseconds == 300)
        let stream = await rig.controller.snapshots()
        let consumer = Task { for await _ in stream {} }
        try await PlaybackTestRig.wait(for: .subscriptionCount(2), in: &events)
        consumer.cancel()
        await consumer.value
        try await PlaybackTestRig.wait(for: .subscriptionCount(1), in: &events)
        #expect(await rig.controller.snapshot.position.microseconds == 300)
    }

    /// 两次安装的后台准备逆序完成时，只接受最新请求；被取代调用抛取消。
    @Test func latePreparationCannotReplaceNewerInstallation() async throws {
        let preparation = PlaybackPreparationProbe()
        let rig = PlaybackTestRig(prepare: { try await preparation.prepare($0, reusing: $1) })
        let composition = try await PlaybackTestRig.composition()
        var ready = preparation.ready.makeAsyncIterator()
        let first = Task { try await rig.controller.setComposition(composition) }
        #expect(await ready.next() == 1)
        let second = Task { try await rig.controller.setComposition(composition) }
        #expect(await ready.next() == 2)
        await preparation.gate.release(2)
        try await second.value
        try await rig.controller.seek(to: PAGTime(microseconds: 123))
        await preparation.gate.release(1)
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await preparation.cancelled == [1])
        #expect(await rig.controller.snapshot.revision == 1)
        #expect(await rig.controller.snapshot.position.microseconds == 123)
    }

    /// 准备期间调用者取消，或文本准备验证失败，均不发布部分合成与新 revision。
    @Test func cancelledAndFailedPreparationKeepCurrentState() async throws {
        let preparation = PlaybackPreparationProbe()
        let rig = PlaybackTestRig(prepare: { try await preparation.prepare($0, reusing: $1) })
        let composition = try await PlaybackTestRig.composition()
        var ready = preparation.ready.makeAsyncIterator()
        let installation = Task { try await rig.controller.setComposition(composition) }
        #expect(await ready.next() == 1)
        installation.cancel()
        await preparation.gate.release(1)
        await #expect(throws: CancellationError.self) { try await installation.value }
        #expect(await preparation.cancelled == [1])
        #expect(await rig.controller.snapshot.state == .empty)
        #expect(await rig.controller.snapshot.revision == 0)

        let normal = PlaybackTestRig()
        try await normal.controller.setComposition(composition)
        try await normal.controller.seek(to: PAGTime(microseconds: 123))
        var invalid = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag")).composition
        var style = try invalid.text(at: 0)
        style.text = "😀"
        try invalid.replaceText(style, at: 0)
        await #expect(throws: PAGError.unsupportedFeature("textColorGlyphs")) {
            try await normal.controller.setComposition(invalid)
        }
        #expect(await normal.controller.snapshot.revision == 1)
        #expect(await normal.controller.snapshot.position.microseconds == 123)
        await #expect(throws: PAGError.invalidArgument("compositionDocument")) {
            try await normal.controller.replaceComposition(invalid)
        }
    }

    /// 释放控制器不被活动任务或订阅反向保活；旧请求失效，订阅结束，迟到回调安全退出。
    @Test func releasingControllerRevokesWorkAndFinishesStream() async throws {
        let probe = PlaybackSubmissionProbe()
        var controller: PAGPlayer? = PAGPlayer(submitter: probe)
        weak let released = controller
        var requests = probe.requests.makeAsyncIterator()
        try await controller?.setComposition(PlaybackTestRig.composition())
        await controller?.updateTarget(.available)
        let active = try #require(await requests.next())
        let stream = try #require(await controller?.snapshots())
        var values = stream.makeAsyncIterator()
        _ = await values.next()
        controller = nil
        #expect(released == nil)
        #expect(!active.gate.permits(active.token))
        #expect(await values.next() == nil)
        try await probe.complete(active)
    }

    /// 有播放意图的同文档替换保留时间/次数/状态；清空后迟到旧帧不能恢复文档。
    @Test func replacementPreservesPlaybackAndClearRevokesEverything() async throws {
        let rig = PlaybackTestRig()
        let composition = try await PlaybackTestRig.composition()
        var requests = rig.probe.requests.makeAsyncIterator()
        var events = rig.events.makeAsyncIterator()
        try await rig.controller.setComposition(composition)
        await rig.controller.setRepeatCount(0)
        await rig.controller.updateTarget(.available)
        let old = try #require(await requests.next())
        try await rig.controller.play()
        let now = UInt64(composition.duration.microseconds + 321)
        rig.clock.set(now)
        await rig.controller.tick(at: now)
        try await rig.controller.replaceComposition(composition)
        let snapshot = await rig.controller.snapshot
        #expect(snapshot.state == .playing && snapshot.position.microseconds == 321)
        #expect(snapshot.completedIterations == 1 && snapshot.repeatCount == 0)
        try await rig.probe.complete(old)
        let edited = try #require(await requests.next())
        #expect(edited.token.compositionRevision == 2)
        try await rig.controller.setComposition(nil)
        try await rig.probe.complete(edited)
        try await PlaybackTestRig.wait(for: .workFinished(edited.token.requestID, accepted: false), in: &events)
        #expect(await rig.controller.snapshot.state == .empty)
        #expect(await rig.controller.snapshot.presentedTime == nil)
        #expect(await rig.controller.snapshot.revision == 3)
    }
}
