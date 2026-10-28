#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 真实Repeater文件的生产Metal输入与单一已挂载drawable回归，不启动Demo。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(2)))
struct MetalRepeaterFileTests {
    /// 600个源帧均能准备根drawable直写pass，并在每帧释放临时附件。
    @Test func allFramesPrepareMetalWithoutLoans() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "repeater.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let size = try PAGSize(width: 200, height: 200)
        let resources = try MetalResources(device: #require(MTLCreateSystemDefaultDevice()))
        for frame in 0..<root.durationFrames {
            let prepared = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: frame, rate: root.frameRate),
                targetSize: size, scale: 1, mode: .aspectFit)
            let batch = try MetalFramePreparation.prepare(prepared, width: 200, height: 200,
                                                          resources: resources)
            #expect(batch.passes.last?.attachment == nil)
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
    }

    /// 真实首帧与旋转中段在同一挂载目标留下不同像素，中段采样点必须有非透明内容。
    @MainActor @Test func firstAndRotatingFramesReachMountedDrawable() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "repeater.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let size = try PAGSize(width: 200, height: 200)
        let points = (0..<4).flatMap { y in (0..<4).map { x in SIMD2(x * 50 + 25, y * 50 + 25) } }
        var frames: [PreparedFrame] = []
        for frame in [Int64(0), 15] {
            frames.append(try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: frame, rate: root.frameRate),
                targetSize: size, scale: 1, mode: .aspectFit))
        }
        let sampled = try await pixels(frames, at: points)
        // 稀疏采样不把首帧所有采样点透明误判为整帧空白；中段固定点能锁定旋转后的真实颜色。
        #expect(sampled[1][6] == SIMD4(1, 136, 251, 255))
        #expect(sampled[0] != sampled[1])
    }

    /// 顺序提交同一挂载目标上的两帧并做诊断读点；结束时关闭测试窗口与资源租约。
    @MainActor private func pixels(_ frames: [PreparedFrame], at points: [SIMD2<Int>]) async throws
        -> [[SIMD4<UInt8>]] {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · Repeater file"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget(width: 200, height: 200)
        let owner = MetalStrokePixelOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            let mutation = try #require(target.mailbox.beginMutation())
            try await owner.configure(target, mutation: mutation)
            try target.mount(to: #require(view.layer), mutation: mutation)
            #expect(target.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: try DisplayGeometry(size: PAGSize(width: 200, height: 200), scale: 1),
                isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            var results: [[SIMD4<UInt8>]] = []
            for frame in frames { results.append(try await owner.pixels(frame, target: target, at: points)) }
            await target.close()
            window.close()
            return results
        } catch {
            await target.close()
            window.close()
            throw error
        }
    }
}

#endif
