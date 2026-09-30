#if os(macOS)
import AppKit
import Metal
import Synchronization
import Testing
@testable import pag_swift

/// 描边与形状属性动画使用真实生产显示桥和RenderOwner，验证提交及迟到结果门禁；没有像素诊断旁路。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct MetalStrokeDrawableTests {
    /// 三类形状分别验证同gate替换、预取消、GPU迟到和resize；已开放文件额外真实提交。
    @MainActor @Test(arguments: MetalShapeFixtureKind.allCases)
    func productionOwnerRejectsStaleShapeFrames(_ kind: MetalShapeFixtureKind) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 240, y: 120, width: 200, height: 150),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · Stroke lifecycle"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
        view.wantsLayer = true
        window.contentView = view
        let box = DisplayTargetBox()
        let hook = Mutex<(@Sendable (RenderEvent) -> Void)?>(nil)
        let encoded = Mutex<[UUID]>([]), completed = Mutex<[UUID]>([])
        let owner = RenderOwner(device: try #require(MTLCreateSystemDefaultDevice()), observe: { event in
            switch event {
            case .encoded(let id, _): encoded.withLock { $0.append(id) }
            case .gpuCompleted(let id, _): completed.withLock { $0.append(id) }
            case .waitingForIdle: break
            }
            // 回调只修改Sendable许可，不在后台触碰窗口，也不在短锁中执行外部代码。
            let action = hook.withLock { $0 }
            action?(event)
        })
        do {
            let mutation = try #require(box.mailbox.beginMutation())
            let info = try await owner.prepareTarget(box, mutation: mutation)
            #expect(!info.isMainThread)
            let geometry = try DisplayGeometry(size: PAGSize(width: 200, height: 150), scale: 1)
            #expect(box.mount(to: try #require(view.layer), mutation: mutation))
            #expect(box.resize(to: geometry, mutation: mutation))
            #expect(box.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: geometry, isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            // 正式字节入口开放后，新增文件也必须通过首/中/末真实提交，语义夹具不能代替它们。
            for name in kind.completeFiles {
                let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
                let scene = try await PreparedScene.prepare(file.composition)
                let source = try #require(file.storage.compositions.last)
                var frames = [Int64(0), source.durationFrames / 2, source.durationFrames - 1]
                // 实际播放曾在这些中间帧失败；首/中/末提交不能替代对应drawable回归。
                if name == "list/19.pag" { frames.append(1) }
                if name == "list/15.pag" { frames.append(14) }
                for frame in frames {
                    try await expectSubmission(owner, MetalStrokeFixtures.request(scene, epoch: mutation, frame: frame))
                }
            }
            let elements = try kind.elements()
            let color = try await MetalStrokeFixtures.scene(elements.color)
            let changing = try await MetalStrokeFixtures.scene(elements.geometry)
            let group = try await MetalStrokeFixtures.scene(elements.group)
            for scene in [color, changing, group] {
                for frame: Int64 in [0, 10] {
                    try await expectSubmission(owner, MetalStrokeFixtures.request(scene, epoch: mutation, frame: frame))
                }
            }
            let cancelled = try MetalStrokeFixtures.request(color, epoch: mutation)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await owner.submit(cancelled)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(!encoded.withLock { $0.contains(cancelled.token.requestID) })

            let gate = PlaybackSubmissionGate()
            let old = try MetalStrokeFixtures.request(color, epoch: mutation, gate: gate)
            let replacement = try MetalStrokeFixtures.request(changing, epoch: mutation, frame: 10, gate: gate, revision: 2)
            gate.allow(old.token)
            hook.withLock { $0 = { event in
                if case .encoded(let id, _) = event, id == old.token.requestID { gate.allow(replacement.token) }
            } }
            await #expect(throws: CancellationError.self) { try await owner.submit(old) }
            hook.withLock { $0 = nil }
            #expect(encoded.withLock { $0.contains(old.token.requestID) })
            #expect(!completed.withLock { $0.contains(old.token.requestID) })
            try await expectSubmission(owner, replacement)
            await #expect(throws: CancellationError.self) { try await owner.submit(old) }

            let late = try MetalStrokeFixtures.request(color, epoch: mutation, frame: 10, gate: gate, revision: 3)
            hook.withLock { $0 = { event in
                if case .gpuCompleted(let id, _) = event, id == late.token.requestID { gate.revoke() }
            } }
            // GPU已经执行也不等于当前播放代仍有效；此确定性回调发生在owner恢复校验之前。
            await #expect(throws: CancellationError.self) { try await owner.submit(late) }
            hook.withLock { $0 = nil }
            #expect(completed.withLock { $0.contains(late.token.requestID) })
            try await expectSubmission(owner, MetalStrokeFixtures.request(color, epoch: mutation, gate: gate, revision: 4))

            let resizing = try MetalStrokeFixtures.request(changing, epoch: mutation, frame: 10, gate: gate, revision: 5)
            hook.withLock { $0 = { event in
                if case .encoded(let id, _) = event, id == resizing.token.requestID { _ = box.mailbox.beginMutation() }
            } }
            await #expect(throws: CancellationError.self) { try await owner.submit(resizing) }
            hook.withLock { $0 = nil }
            #expect(!completed.withLock { $0.contains(resizing.token.requestID) })
            let resizedEpoch = box.mailbox.snapshot.epoch
            #expect(await box.mailbox.waitUntilIdle(for: resizedEpoch))
            let resized = try DisplayGeometry(size: geometry.size, scale: 2)
            #expect(box.resize(to: resized, mutation: resizedEpoch))
            #expect(box.mailbox.finishMutation(resizedEpoch, configuration: DisplayTargetConfiguration(
                geometry: resized, isMounted: true, isActive: true)))
            try await expectSubmission(owner, MetalStrokeFixtures.request(changing, epoch: resizedEpoch, gate: gate, revision: 6))
            await #expect(throws: CancellationError.self) { try await owner.submit(resizing) }
            #expect(!box.mailbox.snapshot.hasLease)
        } catch {
            hook.withLock { $0 = nil }
            await box.shutdown()
            window.close()
            throw error
        }
        await box.shutdown()
        window.close()
    }

    /// 要求真实GPU提交并返回对应源帧时间；targetUnavailable不能当作测试通过。
    private func expectSubmission(_ owner: RenderOwner, _ request: PlaybackFrameRequest) async throws {
        guard case .submitted(let time) = try await owner.submit(request) else {
            Issue.record("生产形状帧没有完成实际drawable提交")
            return
        }
        #expect(time == request.time)
    }
}
#endif
