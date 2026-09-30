import Metal
import QuartzCore
import Testing
@testable import pag_swift

/// 表面异步事务与独占绑定，使用明确租约屏障而非sleep制造可重入窗口。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct PAGSurfaceTests {
    /// 新预约失败时原表面仍归原播放器持有，不能因尝试换目标而悄悄解绑。
    @MainActor @Test func failedTransferKeepsOriginalSurface() async throws {
        let original = try PAGSurface(), occupied = try PAGSurface()
        let player = PAGPlayer(), holder = PAGPlayer(), third = PAGPlayer()
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "red.pag"))
        try await player.setComposition(file.composition)
        try await player.attach(to: original)
        try await holder.attach(to: occupied)
        await #expect(throws: PAGError.surfaceInUse) { try await player.attach(to: occupied) }
        #expect(try await player.render(at: .zero) == .targetUnavailable)
        await #expect(throws: PAGError.surfaceInUse) { try await third.attach(to: original) }
        await player.detachSurface()
        try await third.attach(to: original)
        await third.detachSurface()
        await holder.detachSurface()
    }

    /// 播放器释放会结束订阅并同步撤销预约；迟到异步清理不能夺走新播放器的占用。
    @MainActor @Test func releasedPlayerEndsStreamAndReleasesReservation() async throws {
        let surface = try PAGSurface()
        let stream = try await boundPlayerStream(surface)
        var values = stream.makeAsyncIterator()
        #expect(await values.next()?.state == .empty)
        #expect(await values.next()?.state == nil)
        let next = PAGPlayer()
        try await next.attach(to: surface)
        let competitor = PAGPlayer()
        await #expect(throws: PAGError.surfaceInUse) { try await competitor.attach(to: surface) }
        await next.detachSurface()
    }

    /// 外层任务已取消也必须完成显式拆层；不能用取消跳过关闭显示入口的清理。
    @MainActor @Test func detachCompletesInsideCancelledCaller() async throws {
        let parent = CALayer()
        let surface = try PAGSurface()
        try await surface.attach(to: parent)
        try await surface.resize(to: PAGSize(width: 20, height: 20), scale: 1)
        let cleanup = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await surface.detach()
        }
        await cleanup.value
        #expect(parent.sublayers?.isEmpty != false)
    }

    /// 取消等待布局后恢复已发布状态并解除blocked，后续合法布局仍可完成。
    @MainActor @Test func cancelledResizeRestoresUsableConfiguration() async throws {
        let pair = AsyncStream.makeStream(of: DisplayTargetEvent.self)
        let box = DisplayTargetBox(observe: { pair.continuation.yield($0) })
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = PAGSurface(target: box, owner: RenderOwner(device: device))
        var events = pair.stream.makeAsyncIterator()
        let initial = try #require(box.mailbox.beginMutation())
        let held = try #require(box.mailbox.acquireConfiguration(for: initial))
        let resize = Task { try await surface.resize(to: PAGSize(width: 100, height: 60), scale: 2) }
        guard case .waitingForMutation = await events.next() else { Issue.record("没有等待旧租约"); return }
        resize.cancel()
        box.mailbox.release(held)
        await #expect(throws: CancellationError.self) { try await resize.value }
        #expect(!box.mailbox.snapshot.isBlocked && box.mailbox.snapshot.configuration.geometry == nil)
        try await surface.resize(to: PAGSize(width: 40, height: 30), scale: 1)
        #expect(box.mailbox.snapshot.configuration.geometry?.pixelWidth == 40)
        await surface.detach()
        pair.continuation.finish()
    }

    /// 较新的布局取代旧等待；旧取消不能恢复旧尺寸或解除新事务的blocked。
    @MainActor @Test func newestResizeWinsWhileAccessIsOutstanding() async throws {
        let pair = AsyncStream.makeStream(of: DisplayTargetEvent.self)
        let box = DisplayTargetBox(observe: { pair.continuation.yield($0) })
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = PAGSurface(target: box, owner: RenderOwner(device: device))
        var events = pair.stream.makeAsyncIterator()
        let mutation = try #require(box.mailbox.beginMutation())
        let held = try #require(box.mailbox.acquireConfiguration(for: mutation))
        let first = Task { try await surface.resize(to: PAGSize(width: 100, height: 60), scale: 1) }
        _ = await events.next()
        let latest = Task { try await surface.resize(to: PAGSize(width: 200, height: 80), scale: 2) }
        _ = await events.next()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(box.mailbox.snapshot.isBlocked)
        box.mailbox.release(held)
        try await latest.value
        #expect(box.mailbox.snapshot.configuration.geometry?.pixelWidth == 400)
        #expect(!box.mailbox.snapshot.isBlocked)
        pair.continuation.finish()
    }

    /// 两个布局请求先后被取消时，回滚到最后真正安装的尺寸，不能恢复未提交的旧意图。
    @MainActor @Test func failedNewestResizeRestoresPublishedGeometry() async throws {
        let pair = AsyncStream.makeStream(of: DisplayTargetEvent.self)
        let box = DisplayTargetBox(observe: { pair.continuation.yield($0) })
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = PAGSurface(target: box, owner: RenderOwner(device: device))
        try await surface.resize(to: PAGSize(width: 40, height: 30), scale: 1)
        var events = pair.stream.makeAsyncIterator()
        let mutation = try #require(box.mailbox.beginMutation())
        let held = try #require(box.mailbox.acquireConfiguration(for: mutation))
        let first = Task { try await surface.resize(to: PAGSize(width: 100, height: 60), scale: 1) }
        _ = await events.next()
        let latest = Task { try await surface.resize(to: PAGSize(width: 200, height: 80), scale: 1) }
        _ = await events.next()
        latest.cancel()
        box.mailbox.release(held)
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await latest.value }
        await surface.setPresentationActive(true)
        #expect(box.mailbox.snapshot.configuration.geometry?.pixelWidth == 40)
        #expect(!box.mailbox.snapshot.isBlocked)
        pair.continuation.finish()
    }

    /// 取消尚未完成的预约不能留下surfaceInUse；另一播放器随后可以正常占用并解除。
    @MainActor @Test func cancelledReservationDoesNotLeakOwnership() async throws {
        let pair = AsyncStream.makeStream(of: DisplayTargetEvent.self)
        let box = DisplayTargetBox(observe: { pair.continuation.yield($0) })
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = PAGSurface(target: box, owner: RenderOwner(device: device))
        var events = pair.stream.makeAsyncIterator()
        let mutation = try #require(box.mailbox.beginMutation())
        let held = try #require(box.mailbox.acquireConfiguration(for: mutation))
        let player = PAGPlayer(), other = PAGPlayer()
        let attaching = Task { try await player.attach(to: surface) }
        _ = await events.next()
        attaching.cancel()
        box.mailbox.release(held)
        await #expect(throws: CancellationError.self) { try await attaching.value }
        try await other.attach(to: surface)
        await other.detachSurface()
        #expect(!box.mailbox.snapshot.isBlocked)
        pair.continuation.finish()
    }

    /// 未布局的表面可绑定但不可呈现；占用失败不使原播放器失去目标。
    @MainActor @Test func reservationIsExclusiveUntilDetached() async throws {
        let surface = try PAGSurface()
        let first = PAGPlayer(), second = PAGPlayer()
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "red.pag"))
        try await first.setComposition(file.composition)
        try await second.setComposition(file.composition)
        try await first.attach(to: surface)
        try await first.play()
        #expect(await first.snapshot.state == .suspended)
        await #expect(throws: PAGError.surfaceInUse) { try await second.attach(to: surface) }
        #expect(try await first.render(at: .zero) == .targetUnavailable)
        await first.detachSurface()
        try await second.attach(to: surface)
        #expect(try await second.render(at: .zero) == .targetUnavailable)
        await second.detachSurface()
    }

    /// 仅返回不保活播放器的流，函数返回后局部播放器应销毁并结束生产端。
    @MainActor private func boundPlayerStream(_ surface: PAGSurface) async throws -> AsyncStream<PAGPlaybackSnapshot> {
        let player = PAGPlayer()
        try await player.attach(to: surface)
        return await player.snapshots()
    }
}
