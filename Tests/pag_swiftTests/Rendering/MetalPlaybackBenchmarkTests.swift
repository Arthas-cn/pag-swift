#if os(macOS)
import AppKit
import Metal
import Synchronization
import Testing
@testable import pag_swift

/// 显式启用的真实显示性能探针；计时不读回画面，也不把某台机器的耗时设成CI门槛。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PAG_METAL_BENCHMARK"] == "1"
                && MTLCreateSystemDefaultDevice() != nil, "设置PAG_METAL_BENCHMARK=1并提供主机GPU才运行性能探针"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalPlaybackBenchmarkTests {
    /// 同一1280×720目标连续提交形状、文字、图片和嵌套组，分别报告GPU区间与含drawable等待的端到端时间。
    @MainActor @Test func recordsWarmDirectDrawableSubmission() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · playback benchmark"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        view.wantsLayer = true
        window.contentView = view
        let parent = try #require(view.layer)
        let box = DisplayTargetBox()
        let intervals = Mutex<[UUID: Double]>([:])
        let device = try #require(MTLCreateSystemDefaultDevice())
        let owner = RenderOwner(device: device, observe: { event in
            if case .gpuCompleted(let id, let seconds) = event { intervals.withLock { $0[id] = seconds * 1_000 } }
        })
        do {
            let geometry = try DisplayGeometry(size: PAGSize(width: 640, height: 360), scale: 2)
            let epoch = try #require(box.mailbox.beginMutation())
            let info = try await owner.prepareTarget(box, mutation: epoch)
            #expect(!info.isMainThread)
            try #require(box.mount(to: parent, mutation: epoch) && box.resize(to: geometry, mutation: epoch))
            try #require(box.mailbox.finishMutation(epoch, configuration: DisplayTargetConfiguration(
                geometry: geometry, isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            print("PAG benchmark device=\(info.name) pixels=1280x720 warmup=4 samples=32")
            for name in ["red.pag", "editing/TEXT04.pag", "editing/ImageDecodeTest.pag", "nested-opacity"] {
                let composition: PAGComposition
                if name == "nested-opacity" { composition = try MetalGroupFixtures.composition() }
                else { composition = try await PAGLoader().load(data: PAGFixtures.data(named: name)).composition }
                let scene = try await PreparedScene.prepare(composition)
                var gpu: [Double] = [], total: [Double] = []
                for index in 0..<36 {
                    let gate = PlaybackSubmissionGate()
                    let token = PlaybackRequestToken(documentID: scene.composition.storage.identity, compositionRevision: 1,
                                                     playbackEpoch: UUID(), targetEpoch: epoch, requestID: UUID())
                    gate.allow(token)
                    let request = PlaybackFrameRequest(scene: scene, time: .zero, scaleMode: .aspectFit,
                                                       token: token, gate: gate, endsPlayback: false)
                    let start = ContinuousClock.now
                    let outcome = try await owner.submit(request)
                    let elapsed = start.duration(to: .now).components
                    let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
                    guard case .submitted = outcome else { throw PAGError.renderingFailure("benchmarkDrawableUnavailable") }
                    let interval = try #require(intervals.withLock { $0.removeValue(forKey: token.requestID) })
                    try #require(interval.isFinite && interval > 0)
                    // 预热涵盖管线编译、网格上传与drawable队列填充；单独保留首帧，不混入稳定期分位数。
                    if index == 0 { print("PAG benchmark \(name) first_total_ms=\(milliseconds)") }
                    if index >= 4 { gpu.append(interval); total.append(milliseconds) }
                }
                print("PAG benchmark \(name) GPU_ms \(summary(gpu)) total_ms \(summary(total))")
                #expect(!box.mailbox.snapshot.hasLease && intervals.withLock { $0.isEmpty })
            }
        } catch {
            await box.shutdown()
            window.close()
            throw error
        }
        await box.shutdown()
        window.close()
    }

    /// 输出排序后的中位数、95分位和最大值；样本固定为32个有效提交，空数组属于测试错误。
    private func summary(_ values: [Double]) -> String {
        let sorted = values.sorted()
        return "median=\(sorted[sorted.count / 2]) p95=\(sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1]) max=\(sorted.last!)"
    }
}
#endif
