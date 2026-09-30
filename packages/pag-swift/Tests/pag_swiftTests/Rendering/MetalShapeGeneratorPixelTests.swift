#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 新路径生成器在实际窗口drawable的像素验收；少量读回仅位于测试，生产保持直接显示。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct MetalShapeGeneratorPixelTests {
    /// 检查颜色、尺寸/半径/拓扑往返、孔洞、双向虚线和整体淡出，不以CPU网格通过代替真实GPU画面。
    @MainActor @Test func generatorsDrawIntoMountedDrawable() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 180, y: 160, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · Shape generators"
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
            let red = SIMD4<UInt8>(255, 0, 0, 255)
            for polyStar in [false, true] {
                let scene = try await MetalStrokeFixtures.scene(MetalShapeGeneratorFixtures.color(polyStar: polyStar))
                for (frame, expected): (Int64, SIMD4<UInt8>) in [
                    (0, SIMD4(128, 0, 0, 128)), (5, SIMD4(95, 0, 95, 191)),
                    (10, SIMD4(0, 0, 255, 255)), (0, SIMD4(128, 0, 0, 128))
                ] {
                    let pixels = try await owner.pixels(ShapePathFixtures.plan(scene, at: frame), target: target,
                                                       at: [SIMD2(40, 40), SIMD2(5, 5)])
                    expect(pixels, [expected, .zero])
                }
            }
            for (elements, probe) in [(try MetalShapeGeneratorFixtures.ellipseSize(), SIMD2(70, 50)),
                                     (try MetalShapeGeneratorFixtures.starRadii(), SIMD2(78, 50)),
                                     (try MetalShapeGeneratorFixtures.polygonPoints(), SIMD2(40, 25))] {
                let scene = try await MetalStrokeFixtures.scene(elements)
                for frame: Int64 in [0, 10, 0] {
                    let pixels = try await owner.pixels(ShapePathFixtures.plan(scene, at: frame), target: target,
                                                       at: [SIMD2(50, 50), probe, SIMD2(5, 5)])
                    expect(pixels, [red, frame == 10 ? red : .zero, .zero])
                }
            }
            let hole = try await MetalStrokeFixtures.scene(MetalShapeGeneratorFixtures.ellipseHole())
            expect(try await owner.pixels(ShapePathFixtures.plan(hole, at: 0), target: target,
                at: [SIMD2(50, 50), SIMD2(25, 50), SIMD2(5, 5)]), [.zero, red, .zero])
            for reversed in [false, true] {
                let scene = try await MetalStrokeFixtures.scene(MetalShapeGeneratorFixtures.ellipseDash(reversed: reversed))
                let pixels = try await owner.pixels(ShapePathFixtures.plan(scene, at: 0), target: target,
                                                   at: [SIMD2(57, 31), SIMD2(42, 31), SIMD2(50, 50)])
                expect(pixels, reversed ? [.zero, red, .zero] : [red, .zero, .zero])
            }
            let opacity = try await MetalStrokeFixtures.scene(MetalShapeGeneratorFixtures.groupOpacity())
            for frame: Int64 in [0, 5, 10, 0] {
                let alpha: UInt8 = frame == 0 ? 255 : frame == 5 ? 127 : 0
                let pixels = try await owner.pixels(ShapePathFixtures.plan(opacity, at: frame), target: target,
                                                   at: [SIMD2(30, 50), SIMD2(50, 50), SIMD2(70, 50), SIMD2(5, 5)])
                expect(pixels, [SIMD4(alpha, 0, 0, alpha), SIMD4(alpha, 0, 0, alpha), SIMD4(0, 0, alpha, alpha), .zero])
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

    /// 独立RGBA8预期只允许一次存储量化的一字节误差，未采样抗锯齿边缘。
    private func expect(_ actual: [SIMD4<UInt8>], _ expected: [SIMD4<UInt8>], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.count == expected.count, sourceLocation: sourceLocation)
        for (a, b) in zip(actual, expected) {
            for channel in 0..<4 { #expect(abs(Int(a[channel]) - Int(b[channel])) <= 1, sourceLocation: sourceLocation) }
        }
    }
}
#endif
