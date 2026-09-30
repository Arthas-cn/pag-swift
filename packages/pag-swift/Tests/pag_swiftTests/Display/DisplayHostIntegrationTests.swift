#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 实际surface上的宿主协调与未呈现AppKit窗口生命周期；可见画面由正式App验收。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .serialized, .timeLimit(.minutes(1)))
@MainActor struct DisplayHostIntegrationTests {
    /// 旧布局等待实际租约时接受多次更新，仅安装最新尺寸；相同配置不会更换epoch。
    @Test func pendingLayoutsCoalesceBehindOutstandingLease() async throws {
        let events = AsyncStream.makeStream(of: DisplayTargetEvent.self)
        let box = DisplayTargetBox(observe: { events.continuation.yield($0) })
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = PAGSurface(target: box, owner: RenderOwner(device: device))
        let parent = CALayer()
        let host = DisplayHost(player: PAGPlayer(), parent: parent) { surface }
        await host.waitUntilSettled()
        let epoch = try #require(box.mailbox.beginMutation())
        let lease = try #require(box.mailbox.acquireConfiguration(for: epoch))
        var iterator = events.stream.makeAsyncIterator()
        host.update(.layout(size: CGSize(width: 100, height: 80), scale: 2, isMounted: true, isVisible: false))
        guard case .waitingForMutation = await iterator.next(isolation: MainActor.shared) else {
            box.mailbox.release(lease)
            host.shutdown()
            await host.waitUntilSettled()
            Issue.record("宿主没有等待实际租约")
            return
        }
        for width in 101...120 {
            host.update(.layout(size: CGSize(width: width, height: 80), scale: 2, isMounted: true, isVisible: false))
        }
        #expect(box.mailbox.snapshot.isBlocked)
        box.mailbox.release(lease)
        await host.waitUntilSettled()
        let installed = box.mailbox.snapshot
        #expect(installed.configuration.geometry?.pixelWidth == 240 && !installed.isBlocked && !installed.hasLease)
        host.update(.layout(size: CGSize(width: 120, height: 80), scale: 2, isMounted: true, isVisible: false))
        await host.waitUntilSettled()
        #expect(box.mailbox.snapshot.epoch == installed.epoch)
        host.shutdown()
        await host.waitUntilSettled()
        #expect(parent.sublayers?.isEmpty != false)
        events.continuation.finish()
    }

    /// 新宿主已经接管同一player后，旧宿主关闭不能拆掉新surface的独占预约。
    @Test func staleHostShutdownDoesNotDetachNewHost() async throws {
        let player = PAGPlayer(), intruder = PAGPlayer()
        let first = try PAGSurface(), second = try PAGSurface()
        let old = DisplayHost(player: player, parent: CALayer()) { first }
        await old.waitUntilSettled()
        let current = DisplayHost(player: player, parent: CALayer()) { second }
        await current.waitUntilSettled()
        old.shutdown()
        await old.waitUntilSettled()
        await #expect(throws: PAGError.surfaceInUse) { try await intruder.attach(to: second) }
        current.shutdown()
        await current.waitUntilSettled()
        try await intruder.attach(to: second)
        await intruder.detachSurface()
    }

    /// 新宿主还在等待自己的配置租约时，旧宿主退出不能撤销新请求身份或打断后续预约。
    @Test func oldShutdownPreservesPendingNewHostRequest() async throws {
        let events = AsyncStream.makeStream(of: DisplayTargetEvent.self)
        let box = DisplayTargetBox(observe: { events.continuation.yield($0) })
        let device = try #require(MTLCreateSystemDefaultDevice())
        let second = PAGSurface(target: box, owner: RenderOwner(device: device))
        let player = PAGPlayer(), intruder = PAGPlayer()
        let first = try PAGSurface()
        let old = DisplayHost(player: player, parent: CALayer()) { first }
        await old.waitUntilSettled()
        let epoch = try #require(box.mailbox.beginMutation())
        let lease = try #require(box.mailbox.acquireConfiguration(for: epoch))
        var iterator = events.stream.makeAsyncIterator()
        let current = DisplayHost(player: player, parent: CALayer()) { second }
        guard case .waitingForMutation = await iterator.next(isolation: MainActor.shared) else {
            box.mailbox.release(lease)
            old.shutdown()
            current.shutdown()
            await old.waitUntilSettled()
            await current.waitUntilSettled()
            Issue.record("新宿主没有进入预期的配置等待")
            return
        }
        // 新请求已被player接受，但boundHost仍指旧宿主；二者身份必须分开保存。
        old.shutdown()
        await old.waitUntilSettled()
        box.mailbox.release(lease)
        await current.waitUntilSettled()
        await #expect(throws: PAGError.surfaceInUse) { try await intruder.attach(to: second) }
        #expect(await player.snapshot.failure == nil)
        current.shutdown()
        await current.waitUntilSettled()
        try await intruder.attach(to: second)
        await intruder.detachSurface()
        events.continuation.finish()
    }

    /// 调用方显式切到独立surface后，原View的迟到清理同样不得解除新绑定。
    @Test func explicitSurfaceOutlivesOldHostCleanup() async throws {
        let player = PAGPlayer(), intruder = PAGPlayer()
        let first = try PAGSurface(), independent = try PAGSurface()
        let host = DisplayHost(player: player, parent: CALayer()) { first }
        await host.waitUntilSettled()
        try await player.attach(to: independent)
        host.shutdown()
        await host.waitUntilSettled()
        await #expect(throws: PAGError.surfaceInUse) { try await intruder.attach(to: independent) }
        await player.detachSurface()
        try await intruder.attach(to: independent)
        await intruder.detachSurface()
    }

    /// SwiftPM没有正式App runloop；验证未显示窗口的绑定、零布局、bounds、离窗与拆除。
    @Test func appKitHostTracksUnpresentedWindowLifecycle() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        window.contentView = root
        let player = PAGPlayer()
        try await player.setComposition(PAGLoader().load(data: PAGFixtures.data(named: "red.pag")).composition)
        let view = PAGNSView(player: player)
        view.frame = root.bounds
        root.addSubview(view)
        do {
            await view.waitUntilSettled()
            // 不把orderFront返回误当成系统已允许呈现；测试进程中的窗口保持未显示。
            #expect(!window.isVisible)
            #expect(try await player.render(at: .zero) == .targetUnavailable)
            try await player.play()
            #expect(await player.snapshot.state == .suspended)
            root.isHidden = true
            await view.waitUntilSettled()
            await player.pause()
            root.isHidden = false
            await view.waitUntilSettled()
            #expect(await player.snapshot.state == .paused)
            view.setFrameSize(.zero)
            await view.waitUntilSettled()
            #expect(try await player.render(at: .zero) == .targetUnavailable)
            view.setFrameSize(NSSize(width: 200, height: 160))
            view.setBoundsOrigin(NSPoint(x: 10, y: 15))
            await view.waitUntilSettled()
            #expect(view.layer?.sublayers?.first?.frame == view.bounds)
            view.removeFromSuperview()
            await view.waitUntilSettled()
            #expect(try await player.render(at: .zero) == .targetUnavailable)
            root.addSubview(view)
            await view.waitUntilSettled()
            #expect(await player.snapshot.state == .paused)
            view.dismantle()
            await view.waitUntilSettled()
            await #expect(throws: PAGError.missingSurface) { try await player.render(at: .zero) }
        } catch {
            view.dismantle()
            await view.waitUntilSettled()
            window.close()
            throw error
        }
        window.close()
    }
}
#endif
