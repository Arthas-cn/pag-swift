import QuartzCore
import Testing
@testable import pag_swift

/// 不需要GPU的宿主输入、错误身份和取消测试；真实显示另在平台集成测试验证。
@MainActor struct DisplayHostTests {
    /// 零布局正常停用，正尺寸乘倍率受既有像素预算限制，非法参数不能静默当成隐藏。
    @Test func layoutDistinguishesEmptyAndInvalidGeometry() throws {
        let empty = DisplayHostConfiguration.layout(size: .zero, scale: 2, isMounted: true, isVisible: true)
        #expect(empty.geometry == nil && empty.failure == nil && !empty.isActive && empty.isMounted)
        let visible = DisplayHostConfiguration.layout(size: CGSize(width: 40.25, height: 30), scale: 2, isMounted: true, isVisible: true)
        #expect(visible.geometry?.pixelWidth == 81 && visible.isActive)
        let hidden = DisplayHostConfiguration.layout(size: CGSize(width: 10, height: 10), scale: 2, isMounted: false, isVisible: true)
        #expect(hidden.geometry != nil && !hidden.isActive)
        let invalid = DisplayHostConfiguration.layout(size: CGSize(width: 10, height: 10), scale: .nan, isMounted: true, isVisible: true)
        #expect(invalid.failure == .invalidArgument("scale") && !invalid.isActive)
        let excessive = DisplayHostConfiguration.layout(size: CGSize(width: 20_000, height: 10), scale: 1, isMounted: true, isVisible: true)
        #expect(excessive.failure == .resourceLimitExceeded("displayPixels"))
    }

    /// 旧请求、已撤销请求和公开detach取代的请求都不能发布失败，最新有效宿主可以。
    @Test func failuresRespectHostIdentityAndExplicitControl() async throws {
        let player = PAGPlayer()
        let first = DisplayHostToken(), second = DisplayHostToken(), latest = DisplayHostToken()
        try await player.beginHostRequest(first)
        try await player.beginHostRequest(second)
        await player.reportHostFailure(.graphicsUnavailable, token: first)
        #expect(await player.snapshot.state == .empty)
        second.cancel()
        await player.reportHostFailure(.graphicsUnavailable, token: second)
        #expect(await player.snapshot.state == .empty)
        await #expect(throws: CancellationError.self) { try await player.beginHostRequest(second) }
        try await player.beginHostRequest(latest)
        await player.detachSurface()
        await player.reportHostFailure(.graphicsUnavailable, token: latest)
        #expect(await player.snapshot.state == .empty)
        try await player.beginHostRequest(latest)
        await player.reportHostFailure(.graphicsUnavailable, token: latest)
        #expect(await player.snapshot.failure == .graphicsUnavailable)
    }

    /// 初始化尚未执行时连续换player只处理最新意图，设备失败落到最新控制器，不污染旧对象。
    @Test func latestPlayerReceivesCreationFailure() async {
        let first = PAGPlayer(), latest = PAGPlayer()
        var attempts = 0
        let host = DisplayHost(player: first, parent: CALayer()) {
            attempts += 1
            throw PAGError.graphicsUnavailable
        }
        host.setPlayer(latest)
        await host.waitUntilSettled()
        #expect(attempts == 1)
        #expect(await first.snapshot.state == .empty)
        #expect(await latest.snapshot.failure == .graphicsUnavailable)
        host.shutdown()
        await host.waitUntilSettled()
    }

    /// 视图同一同步周期就被拆除时不创建任何设备资源，不把正常取消发布为错误。
    @Test func immediateShutdownDoesNotCreateSurface() async {
        let player = PAGPlayer()
        var attempts = 0
        let host = DisplayHost(player: player, parent: CALayer()) {
            attempts += 1
            throw PAGError.graphicsUnavailable
        }
        host.shutdown()
        await host.waitUntilSettled()
        #expect(attempts == 0)
        #expect(await player.snapshot.state == .empty)
    }
}
