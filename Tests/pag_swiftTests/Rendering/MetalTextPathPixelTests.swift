#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 真实文字路径文件经生产RenderOwner提交到已挂载drawable后的像素分布。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(2)))
struct MetalTextPathPixelTests {
    /// 九份真实文件均须实际显字，反向/关闭切线旋转的成对输入须改变画面。
    @MainActor @Test func realModesProduceDistinctMountedDrawablePixels() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 256, height: 256),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · Text Path"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 256, height: 256))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget(width: 256, height: 256)
        let owner = MetalStrokePixelOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            let mutation = try #require(target.mailbox.beginMutation())
            try await owner.configure(target, mutation: mutation)
            try target.mount(to: #require(view.layer), mutation: mutation)
            #expect(target.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: try DisplayGeometry(size: PAGSize(width: 256, height: 256), scale: 1),
                isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            let points = (0..<64).flatMap { row in (0..<64).map { column in
                SIMD2<Int>(2 + column * 4, 2 + row * 4)
            } }
            let names = ["TextPathBox.pag", "TextPathBox2.pag", "TextPathBoxReversed.pag",
                "TextPathClosedPath.pag", "TextPathCommon.pag", "TextPathForceAlignment.pag",
                "TextPathForceAlignment2.pag", "TextPathNotPerpendicular.pag", "TextPathReversed.pag"]
            var samples: [String: [SIMD4<UInt8>]] = [:]
            for name in names {
                let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
                let scene = try await PreparedScene.prepare(file.composition)
                let frame = try await FramePlanner.prepare(scene, at: .zero,
                    targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .stretch)
                let result = try await owner.pixels(frame, target: target, at: points)
                #expect(result.contains(where: { $0.w > 0 }), "file=\(name)")
                samples[name] = result
            }
            #expect(samples["TextPathBox.pag"] != samples["TextPathBoxReversed.pag"])
            #expect(samples["TextPathCommon.pag"] != samples["TextPathReversed.pag"])
            #expect(samples["TextPathCommon.pag"] != samples["TextPathNotPerpendicular.pag"])
            #expect(samples["TextPathForceAlignment.pag"] != samples["TextPathForceAlignment2.pag"])
            await target.close()
            window.close()
        } catch {
            await target.close()
            window.close()
            throw error
        }
    }
}
#endif
