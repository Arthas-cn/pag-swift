#if os(macOS)
import AppKit
import Dispatch
import Metal
import Synchronization
import Testing
@testable import pag_swift

/// 公开播放器与独立CALayer表面的真实连接；不依赖P6宿主或测试手动tick。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .serialized, .timeLimit(.minutes(1)))
struct PAGPlayerDisplayTests {
    /// 拆层后同一播放器重挂仍须激活；随后空播放器接管旧表面，必须完成透明GPU提交。
    @MainActor @Test func remountAndEmptyHandoffPreserveLifecycleRules() async throws {
        let rendering = AsyncStream.makeStream(of: RenderEvent.self)
        let playback = AsyncStream.makeStream(of: PlaybackEvent.self)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let box = DisplayTargetBox()
        let owner = RenderOwner(device: device, observe: { rendering.continuation.yield($0) })
        let surface = PAGSurface(target: box, owner: owner)
        try await withSurface(surface) { surface, parent in
            let player = PAGPlayer()
            try await player.setComposition(PAGLoader().load(data: PAGFixtures.data(named: "red.pag")).composition)
            try await player.attach(to: surface)
            #expect(try await player.render(at: .zero) == .submitted(time: .zero, revision: 1))
            await player.pause()
            await surface.detach()
            #expect(parent.sublayers?.isEmpty != false)
            try await surface.attach(to: parent)
            #expect(try await player.render(at: .zero) == .targetUnavailable)
            await surface.setPresentationActive(true)
            #expect(await player.snapshot.state == .paused)
            #expect(try await player.render(at: .zero) == .submitted(time: .zero, revision: 1))
            await player.detachSurface()
            #expect(parent.sublayers?.count == 1)
            // 解除控制不会偷偷拆层；空的新拥有者必须通过自己的gate清掉已呈现内容。
            var operations = PlaybackOperations()
            operations.observe = { playback.continuation.yield($0) }
            let empty = PAGPlayer(submitter: owner, operations: operations)
            var rendered = rendering.stream.makeAsyncIterator(), finished = playback.stream.makeAsyncIterator()
            try await empty.attach(to: surface)
            try await waitForClear(rendered: &rendered, finished: &finished)
            let snapshot = await empty.snapshot
            #expect(snapshot.state == .empty && snapshot.presentedTime == nil)
            #expect(!box.mailbox.snapshot.hasLease)
            await empty.detachSurface()
        }
        rendering.continuation.finish()
        playback.continuation.finish()
    }

    /// 公开nil安装和隐藏恢复真正编码透明clear，并在GPU结束后确认，始终保持empty与无播放时间。
    @MainActor @Test func clearingCompositionSubmitsTransparentDrawablePass() async throws {
        let rendering = AsyncStream.makeStream(of: RenderEvent.self)
        let playback = AsyncStream.makeStream(of: PlaybackEvent.self)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let box = DisplayTargetBox()
        let owner = RenderOwner(device: device, observe: { rendering.continuation.yield($0) })
        let surface = PAGSurface(target: box, owner: owner)
        var operations = PlaybackOperations()
        operations.observe = { playback.continuation.yield($0) }
        let player = PAGPlayer(submitter: owner, operations: operations)
        try await withSurface(surface) { surface, _ in
            var rendered = rendering.stream.makeAsyncIterator(), finished = playback.stream.makeAsyncIterator()
            // 空播放器首次绑定也会清理可能从其他拥有者留下的显示内容。
            try await player.attach(to: surface)
            try await waitForClear(rendered: &rendered, finished: &finished)
            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "red.pag"))
            try await player.setComposition(file.composition)
            _ = try await player.render(at: .zero)
            try await player.setComposition(nil)
            try await waitForClear(rendered: &rendered, finished: &finished)
            let empty = await player.snapshot
            #expect(empty.state == .empty && empty.presentedTime == nil && empty.revision == 2)
            await surface.setPresentationActive(false)
            try await player.setComposition(nil)
            #expect(!box.mailbox.snapshot.hasLease)
            await surface.setPresentationActive(true)
            try await waitForClear(rendered: &rendered, finished: &finished)
            let restored = await player.snapshot
            #expect(restored.state == .empty && restored.presentedTime == nil && restored.revision == 3)
            #expect(!box.mailbox.snapshot.hasLease)
            await player.detachSurface()
        }
        rendering.continuation.finish()
        playback.continuation.finish()
    }

    /// 平台无刷新源时不能伪报自动推进；目标恢复后仍由宿主重新激活，不使用sleep模拟屏幕。
    @MainActor @Test func missingDisplayLinkSuspendsPlayback() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = PAGSurface(target: DisplayTargetBox(), owner: RenderOwner(device: device), refreshFactory: { _, _ in nil })
        try await withSurface(surface) { surface, _ in
            let player = PAGPlayer()
            try await player.setComposition(PAGLoader().load(data: PAGFixtures.data(named: "red.pag")).composition)
            try await player.attach(to: surface)
            let snapshots = await player.snapshots()
            try await player.play()
            var suspended = false
            for await value in snapshots {
                if value.state == .suspended { suspended = true; break }
                if value.state == .failed { throw value.failure ?? PAGError.graphicsUnavailable }
            }
            #expect(suspended)
            #expect(try await player.render(at: .zero) == .targetUnavailable)
            await player.detachSurface()
        }
    }

    /// 公开render完成真实提交，系统display link推进到末帧；隐藏恢复不覆盖主动暂停意图。
    @MainActor @Test func publicPlayerRendersAndFinishesFromSystemRefresh() async throws {
        try await withSurface { surface, _ in
            let player = PAGPlayer()
            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "red.pag"))
            try await player.setComposition(file.composition)
            try await player.attach(to: surface)
            let rendered = try await player.render(at: .zero)
            #expect(rendered == .submitted(time: .zero, revision: 1))
            let snapshots = await player.snapshots()
            try await player.seek(to: PAGProgress.end)
            try await player.play()
            var finished: PAGPlaybackSnapshot?
            for await value in snapshots {
                if value.state == .failed { throw value.failure ?? PAGError.renderingFailure("displayTestFailure") }
                if value.state == .finished { finished = value; break }
            }
            let end = try #require(finished)
            #expect(end.completedIterations == 1 && end.position.microseconds == file.composition.duration.microseconds - 1)
            // 第449帧/30fps的代表微秒按合同向上取整，避免重新floor后落到上一帧。
            #expect(end.presentedTime?.microseconds == 14_966_667)
            await surface.setPresentationActive(false)
            try await player.rewind()
            try await player.play()
            #expect(await player.snapshot.state == .suspended)
            await player.pause()
            let paused = await player.snapshot.position
            await surface.setPresentationActive(true)
            let resumed = await player.snapshot
            #expect(resumed.state == .paused && resumed.position == paused)
            try await surface.resize(to: PAGSize(width: 300, height: 200), scale: 2)
            #expect(try await player.render(at: .zero) == .submitted(time: .zero, revision: 1))
            await surface.detach()
            #expect(try await player.render(at: .zero) == .targetUnavailable)
            await player.detachSurface()
            await #expect(throws: PAGError.missingSurface) { try await player.render(at: .zero) }
        }
    }

    /// GPU完成回调被控制屏障暂停时交接绑定，二者等实际owner退出后才能继续。
    @MainActor @Test func transferWaitsForCompletedOwnerToExit() async throws {
        let signals = AsyncStream.makeStream(of: RenderEvent.self, bufferingPolicy: .bufferingNewest(1))
        let stopOnce = Mutex(false)
        let proceed = DispatchSemaphore(value: 0)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let box = DisplayTargetBox()
        let owner = RenderOwner(device: device, observe: { event in
            signals.continuation.yield(event)
            if case .gpuCompleted = event, stopOnce.withLock({ state in let old = state; state = false; return old }) {
                // 只暂停系统完成回调，owner执行器仍可接收交接屏障；不阻塞主actor或协作执行器。
                proceed.wait()
            }
        })
        let surface = PAGSurface(target: box, owner: owner)
        try await withSurface(surface) { surface, _ in
            defer { proceed.signal() }
            let first = PAGPlayer(), second = PAGPlayer()
            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "red.pag"))
            try await first.setComposition(file.composition)
            try await second.setComposition(file.composition)
            try await first.attach(to: surface)
            _ = try await first.render(at: .zero)
            var events = signals.stream.makeAsyncIterator()
            // 前一次render已结束，丢弃它已有的编码/完成诊断，之后的屏障只针对新请求。
            while let event = await events.next() { if case .gpuCompleted = event { break } }
            stopOnce.withLock { $0 = true }
            let render = Task { try await first.render(at: PAGTime(microseconds: 100_000)) }
            while let event = await events.next() { if case .gpuCompleted = event { break } }
            let detach = Task { await first.detachSurface() }
            while let event = await events.next() { if case .waitingForIdle = event { break } }
            let attach = Task { try await second.attach(to: surface) }
            while let event = await events.next() { if case .waitingForIdle = event { break } }
            proceed.signal()
            await detach.value
            try await attach.value
            await #expect(throws: CancellationError.self) { try await render.value }
            #expect(try await second.render(at: .zero) == .submitted(time: .zero, revision: 1))
            #expect(!box.mailbox.snapshot.hasLease)
            await second.detachSurface()
        }
        signals.continuation.finish()
    }

    /// 在真实窗口提供独立表面及可重挂的普通父层，任何失败也排空、拆层并关闭窗口。
    @MainActor private func withSurface(_ supplied: PAGSurface? = nil,
                                        body: @MainActor (PAGSurface, CALayer) async throws -> Void) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · public playback"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.wantsLayer = true
        window.contentView = view
        let parent = try #require(view.layer)
        let surface = try supplied ?? PAGSurface()
        do {
            try await surface.attach(to: parent)
            try await surface.resize(to: PAGSize(width: 320, height: 240), scale: 1)
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            await surface.setPresentationActive(true)
            try await body(surface, parent)
        } catch {
            await surface.detach()
            window.close()
            throw error
        }
        await surface.detach()
        #expect(parent.sublayers?.isEmpty != false)
        window.close()
    }

    /// 同一零图元请求必须先完成GPU再被控制actor接受，不能把编码完成当作清屏完成。
    @MainActor private func waitForClear(rendered: inout AsyncStream<RenderEvent>.Iterator,
                                         finished: inout AsyncStream<PlaybackEvent>.Iterator) async throws {
        var clear: UUID?
        while let event = await rendered.next(isolation: MainActor.shared) {
            if case .encoded(let id, let count) = event, count == 0 { clear = id; break }
        }
        let id = try #require(clear)
        var completed = false
        while let event = await rendered.next(isolation: MainActor.shared) {
            if case .gpuCompleted(let requestID, _) = event, requestID == id { completed = true; break }
        }
        try #require(completed)
        try await PlaybackTestRig.wait(for: .workFinished(id, accepted: true), in: &finished)
    }
}
#endif
