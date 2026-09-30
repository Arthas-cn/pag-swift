#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 新形状属性在真实显示drawable上的像素验收；读取诊断只在Tests，生产仍直接显示且不读回。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct MetalShapePropertyPixelTests {
    /// 颜色/alpha、交叉整体alpha、透明穿零、组位置和矩形尺寸/圆角往返符合独立坐标和RGBA预期。
    @MainActor @Test func verifiesAnimatedPropertiesOnMountedDrawable() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 160, y: 140, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · Shape properties"
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

            let color = try await MetalStrokeFixtures.scene(MetalShapePropertyFixtures.color())
            for (frame, expected): (Int64, SIMD4<UInt8>) in [
                (0, SIMD4(128, 0, 0, 128)), (5, SIMD4(95, 0, 95, 191)),
                (10, SIMD4(0, 0, 255, 255)), (0, SIMD4(128, 0, 0, 128))
            ] {
                let pixels = try await owner.pixels(ShapePathFixtures.plan(color, at: frame), target: target,
                    at: [SIMD2(40, 40), SIMD2(5, 5)])
                expect(pixels, [expected, .zero])
            }
            let opacity = try await MetalStrokeFixtures.scene(MetalShapePropertyFixtures.groupOpacity())
            for frame: Int64 in [0, 5, 10, 0] {
                let alpha: UInt8 = frame == 0 ? 255 : frame == 5 ? 127 : 0
                let pixels = try await owner.pixels(ShapePathFixtures.plan(opacity, at: frame), target: target,
                    at: [SIMD2(25, 35), SIMD2(40, 35), SIMD2(60, 35), SIMD2(5, 5)])
                // 重叠处和红色单臂alpha相同；不能在两个子组各乘alpha后再叠加。
                expect(pixels, [SIMD4(alpha, 0, 0, alpha), SIMD4(alpha, 0, 0, alpha), SIMD4(0, 0, alpha, alpha), .zero])
            }
            let moving = try await MetalStrokeFixtures.scene(MetalShapePropertyFixtures.movingGroup())
            let rectangle = try await MetalStrokeFixtures.scene(MetalShapePropertyFixtures.rectangle())
            let red = SIMD4<UInt8>(255, 0, 0, 255)
            for frame: Int64 in [0, 10, 0] {
                let moved = try await owner.pixels(ShapePathFixtures.plan(moving, at: frame), target: target,
                    at: [SIMD2(30, 30), SIMD2(70, 30)])
                expect(moved, frame == 10 ? [.zero, red] : [red, .zero])
                let resized = try await owner.pixels(ShapePathFixtures.plan(rectangle, at: frame), target: target,
                    at: [SIMD2(40, 40), SIMD2(22, 40), SIMD2(21, 21)])
                expect(resized, [red, frame == 10 ? red : .zero, .zero])
            }
            #expect(target.mailbox.snapshot.hasLease == false)
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// RGBA8一次存储允许一个字节量化误差；预期由源轨道端值、线性中点与像素位置独立确定。
    private func expect(_ actual: [SIMD4<UInt8>], _ expected: [SIMD4<UInt8>],
                        sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.count == expected.count, sourceLocation: sourceLocation)
        for (a, b) in zip(actual, expected) {
            for channel in 0..<4 { #expect(abs(Int(a[channel]) - Int(b[channel])) <= 1, sourceLocation: sourceLocation) }
        }
    }
}
#endif
