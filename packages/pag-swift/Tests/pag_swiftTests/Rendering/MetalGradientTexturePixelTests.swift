#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 真实复杂alpha渐变通过小输入LUT直接写已挂载drawable后的像素行为。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalGradientTexturePixelTests {
    /// grad_alpha必须呈现多个颜色和alpha值，而非空图、单一边色或只有输入纹理未实际绘制。
    @MainActor @Test func realAlphaGradientDrawsVariablePixels() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 256, height: 256),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · Gradient Texture"
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
            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "gradient/grad_alpha.pag"))
            let scene = try await PreparedScene.prepare(file.composition)
            let frame = try await FramePlanner.prepare(scene, at: .zero,
                targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .stretch)
            let points = (0..<64).flatMap { row in (0..<64).map { column in
                SIMD2<Int>(2 + column * 4, 2 + row * 4)
            } }
            let pixels = try await owner.pixels(frame, target: target, at: points)
            let visible = pixels.filter { $0.w > 0 }
            #expect(!visible.isEmpty)
            #expect(Set(visible.map(\.w)).count > 1)
            #expect(Set(visible.map { SIMD3($0.x, $0.y, $0.z) }).count > 1)
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
