#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 在真实显示drawable上核对描边像素；与生产RenderOwner生命周期测试共同构成显示门禁。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct MetalStrokePixelTests {
    /// 交叉单次alpha、混合paint与子组alpha、颜色和宽度动画都必须得到独立手算的像素值。
    @MainActor @Test func verifiesStrokePixelsOnMountedDrawable() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · Stroke pixels"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget()
        let owner = MetalStrokePixelOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            let mutation = try #require(target.mailbox.beginMutation())
            try await owner.configure(target, mutation: mutation)
            try target.mount(to: #require(view.layer), mutation: mutation)
            #expect(target.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: try DisplayGeometry(size: PAGSize(width: 100, height: 100), scale: 1),
                isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            let cross = try await MetalStrokeFixtures.scene(MetalStrokeFixtures.crossing())
            let crossing = try await owner.pixels(ShapePathFixtures.plan(cross, at: 0), target: target,
                at: [SIMD2(25, 25), SIMD2(12, 25), SIMD2(12, 12)])
            expect(crossing, [SIMD4(128, 0, 0, 128), SIMD4(128, 0, 0, 128), .zero])

            let group = try await MetalStrokeFixtures.scene(MetalStrokeFixtures.mixedGroup())
            let grouped = try await owner.pixels(ShapePathFixtures.plan(group, at: 0), target: target,
                at: [SIMD2(16, 40), SIMD2(20, 40), SIMD2(40, 40), SIMD2(5, 5)])
            expect(grouped, [SIMD4(128, 0, 0, 128), SIMD4(0, 0, 128, 128), SIMD4(0, 128, 0, 128), .zero])

            let color = try await MetalStrokeFixtures.scene(MetalStrokeFixtures.animatedColor())
            for frame: Int64 in [0, 10, 0] {
                let pixels = try await owner.pixels(ShapePathFixtures.plan(color, at: frame), target: target, at: [SIMD2(25, 25)])
                expect(pixels, [frame == 10 ? SIMD4(0, 0, 255, 255) : SIMD4(128, 0, 0, 128)])
            }
            let width = try await MetalStrokeFixtures.scene(MetalStrokeFixtures.animatedWidth())
            for frame: Int64 in [0, 10, 0] {
                let pixels = try await owner.pixels(ShapePathFixtures.plan(width, at: frame), target: target, at: [SIMD2(16, 16)])
                expect(pixels, [frame == 10 ? SIMD4(128, 0, 0, 128) : .zero])
            }
            #expect(!target.mailbox.snapshot.hasLease)
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// 预乘通道由几何位置和源颜色手算，仅允许一次RGBA8存储量化误差。
    private func expect(_ actual: [SIMD4<UInt8>], _ expected: [SIMD4<UInt8>]) {
        #expect(actual.count == expected.count)
        for (a, b) in zip(actual, expected) {
            for channel in 0..<4 { #expect(abs(Int(a[channel]) - Int(b[channel])) <= 1) }
        }
    }
}
#endif
