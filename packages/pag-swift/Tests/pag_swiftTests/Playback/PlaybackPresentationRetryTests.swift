import Testing
@testable import pag_swift

/// 内容首帧暂时没有drawable时的刷新意图；即使没有播放意图也要恢复，且不得推进暂停时间。
struct PlaybackPresentationRetryTests {
    /// ready/paused的提交暂不可用会启用真实刷新，恢复成功后关闭额外刷新并保留原时间。
    @Test(arguments: [false, true]) func unavailableStaticContentRequestsRefresh(paused: Bool) async throws {
        let rig = PlaybackTestRig()
        var requests = rig.probe.requests.makeAsyncIterator(), events = rig.events.makeAsyncIterator()
        try await rig.controller.setComposition(PlaybackTestRig.composition())
        if paused { await rig.controller.pause() }
        await rig.controller.updateTarget(.available)
        let first = try #require(await requests.next())
        #expect(!(await rig.controller.requiresDisplayRefresh))
        await rig.probe.resolve(first, result: .success(.targetUnavailable))
        try await PlaybackTestRig.wait(for: .workFinished(first.token.requestID, accepted: true), in: &events)
        #expect(await rig.controller.requiresDisplayRefresh)
        rig.clock.set(5_000_000)
        await rig.controller.updateTarget(.available)
        await rig.controller.tick(at: 5_000_000)
        let restored = try #require(await requests.next())
        #expect(restored.time == .zero)
        try await rig.probe.complete(restored)
        try await PlaybackTestRig.wait(for: .workFinished(restored.token.requestID, accepted: true), in: &events)
        let snapshot = await rig.controller.snapshot
        #expect(snapshot.position == .zero && snapshot.presentedTime == .zero)
        #expect(snapshot.state == (paused ? .paused : .ready))
        #expect(!(await rig.controller.requiresDisplayRefresh))
    }

    /// 已经需要恢复的静态内容在解除绑定后不再请求刷新；不会用后台循环替代显示目标。
    @Test func detachingStopsPresentationRetry() async throws {
        let rig = PlaybackTestRig()
        var requests = rig.probe.requests.makeAsyncIterator(), events = rig.events.makeAsyncIterator()
        try await rig.controller.setComposition(PlaybackTestRig.composition())
        await rig.controller.updateTarget(.available)
        let first = try #require(await requests.next())
        await rig.probe.resolve(first, result: .success(.targetUnavailable))
        try await PlaybackTestRig.wait(for: .workFinished(first.token.requestID, accepted: true), in: &events)
        #expect(await rig.controller.requiresDisplayRefresh)
        await rig.controller.detachSurface()
        #expect(!(await rig.controller.requiresDisplayRefresh))
    }
}
