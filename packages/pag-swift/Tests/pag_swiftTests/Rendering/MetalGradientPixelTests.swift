#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 渐变最终写入实际窗口drawable的像素验收；测试读回不进入生产播放路径。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要Metal设备"), .timeLimit(.minutes(1)))
struct MetalGradientPixelTests {
    /// 在同一真实显示目标依次验证两种布局、色标、组矩阵/局部附件、描边和动画管线切换。
    @MainActor @Test func gradientsDrawIntoMountedDrawable() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 180, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · Gradients"
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
                geometry: try DisplayGeometry(size: PAGSize(width: 100, height: 100), scale: 1), isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            try await verifyStops(owner, target)
            try await verifyTransforms(owner, target)
            try await verifyAnimations(owner, target)
            try await verifyGroupsAndStrokes(owner, target)
            #expect(!target.mailbox.snapshot.hasLease)
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// 透明RGB中值保留未预乘插值，midpoint0.25和t0.5跳变依独立字节期望验证。
    private func verifyStops(_ owner: MetalStrokePixelOwner, _ target: MetalStrokePixelTarget) async throws {
        let colors = GradientColorFixtures.colors(alpha: [(0, 0), (1, 255)])
        for kind in [SourceGradientKind.linear, .radial] {
            let scene = try await MetalStrokeFixtures.scene(MetalGradientFixtures.filled(MetalGradientFixtures.material(kind: kind, colors: colors)))
            let points = [20, 35, 50, 65, 80].map { SIMD2($0, 50) } + [SIMD2(5, 5)]
            let expected = [0.0, 0.25, 0.5, 0.75, 1].map { rgba(1 - $0, 0, $0, alpha: $0) } + [.zero]
            expect(try await owner.pixels(ShapePathFixtures.plan(scene, at: 0), target: target, at: points), expected)
        }
        let midpoint = GradientColorFixtures.colors(colorMidpoint: 0.25)
        let middle = try await MetalStrokeFixtures.scene(MetalGradientFixtures.filled(MetalGradientFixtures.material(kind: .radial, colors: midpoint)))
        expect(try await owner.pixels(ShapePathFixtures.plan(middle, at: 0), target: target,
            at: [SIMD2(35, 50), SIMD2(50, 50)]), [SIMD4(127, 0, 127, 255), SIMD4(85, 0, 170, 255)])
        let abrupt = try await MetalStrokeFixtures.scene(MetalGradientFixtures.filled(MetalGradientFixtures.material(kind: .radial,
            colors: MetalGradientFixtures.hardstop())))
        expect(try await owner.pixels(ShapePathFixtures.plan(abrupt, at: 0), target: target,
            at: [SIMD2(49, 50), SIMD2(50, 50), SIMD2(51, 50)]),
            [SIMD4(131, 123, 0, 255), SIMD4(0, 255, 0, 255), SIMD4(0, 247, 8, 255)])
    }

    /// 显示坐标先还原真实局部，再逆paint；shear、非均匀/负缩放和2^24重定位不能用显示端点投影替代。
    private func verifyTransforms(_ owner: MetalStrokePixelOwner, _ target: MetalStrokePixelTarget) async throws {
        for kind in [SourceGradientKind.linear, .radial] {
            let scene = try await MetalStrokeFixtures.scene(MetalGradientFixtures.sheared(kind: kind))
            // 对像素中心(60.5,40.5)手解P逆，得到local(17.625,15.25)。
            let t = kind == .linear ? 17.625 / 40 : (17.625 * 17.625 + 15.25 * 15.25).squareRoot() / 40
            expect(try await owner.pixels(ShapePathFixtures.plan(scene, at: 0), target: target,
                at: [SIMD2(60, 40), SIMD2(5, 5)]), [rgba(1 - t, 0, t), .zero])
        }
        let mirrored = try await MetalStrokeFixtures.scene(MetalGradientFixtures.mirrored())
        let t = (80 - 40.5) / 2 / 40
        expect(try await owner.pixels(ShapePathFixtures.plan(mirrored, at: 0), target: target,
            at: [SIMD2(40, 30), SIMD2(5, 5)]), [rgba(1 - t, 0, t), .zero])
        let large = try await MetalGradientFixtures.largeOriginScene()
        expect(try await owner.pixels(ShapePathFixtures.plan(large, at: 0), target: target,
            at: [SIMD2(30, 30), SIMD2(5, 5)]), [rgba(1 - 20.5 / 40, 0, 20.5 / 40), .zero])
    }

    /// 颜色程序变化与半径退化往返各自更新，既有drawable不会残留上一管线或上一帧的颜色。
    private func verifyAnimations(_ owner: MetalStrokePixelOwner, _ target: MetalStrokePixelTarget) async throws {
        let color = try await MetalStrokeFixtures.scene(MetalGradientFixtures.animatedColor())
        for (frame, expected): (Int64, SIMD4<UInt8>) in [
            (0, SIMD4(128, 0, 128, 255)), (5, SIMD4(64, 64, 128, 255)),
            (10, SIMD4(0, 128, 128, 255)), (0, SIMD4(128, 0, 128, 255))
        ] {
            expect(try await owner.pixels(ShapePathFixtures.plan(color, at: frame), target: target, at: [SIMD2(50, 50)]), [expected])
        }
        let radius = try await MetalStrokeFixtures.scene(MetalGradientFixtures.animatedRadius())
        for (frame, expected): (Int64, SIMD4<UInt8>) in [
            (0, SIMD4(0, 0, 255, 255)), (5, SIMD4(128, 0, 128, 255)),
            (10, SIMD4(191, 0, 64, 255)), (0, SIMD4(0, 0, 255, 255))
        ] {
            expect(try await owner.pixels(ShapePathFixtures.plan(radius, at: frame), target: target, at: [SIMD2(35, 50)]), [expected])
        }
    }

    /// 局部组附件只乘一次整体alpha；反向dash只改变覆盖，宽度动画不改变渐变方向。
    private func verifyGroupsAndStrokes(_ owner: MetalStrokePixelOwner, _ target: MetalStrokePixelTarget) async throws {
        let opacity = try await MetalStrokeFixtures.scene(MetalGradientFixtures.groupOpacity())
        for frame: Int64 in [0, 5, 10, 0] {
            let alpha = frame == 5 ? 127.0 / 255 : frame == 10 ? 0 : 1
            let expected = [5.0 / 60, 0.5, 55.0 / 60].map { rgba(1 - $0, 0, $0, alpha: alpha) } + [.zero]
            expect(try await owner.pixels(ShapePathFixtures.plan(opacity, at: frame), target: target,
                at: [SIMD2(25, 50), SIMD2(50, 50), SIMD2(75, 50), SIMD2(5, 5)]), expected)
        }
        for reversed in [false, true] {
            let scene = try await MetalStrokeFixtures.scene(MetalGradientFixtures.dashedStroke(reversed: reversed))
            let x = reversed ? 35 : 25, other = reversed ? 25 : 35
            let t = Double(x - 20) / 60
            for frame: Int64 in [0, 10, 0] {
                let color = rgba(1 - t, 0, t)
                expect(try await owner.pixels(ShapePathFixtures.plan(scene, at: frame), target: target,
                    at: [SIMD2(x, 50), SIMD2(other, 50), SIMD2(x, 55)]), [color, .zero, frame == 10 ? color : .zero])
            }
        }
    }

    /// 独立Double参照只做RGBA8量化，输入是上述手算未预乘通道和单次alpha。
    private func rgba(_ red: Double, _ green: Double, _ blue: Double, alpha: Double = 1) -> SIMD4<UInt8> {
        SIMD4(UInt8((red * alpha * 255).rounded()), UInt8((green * alpha * 255).rounded()),
              UInt8((blue * alpha * 255).rounded()), UInt8((alpha * 255).rounded()))
    }

    /// 远离几何边缘的像素只允许一次存储量化的一字节误差，失败指明点号与通道。
    private func expect(_ actual: [SIMD4<UInt8>], _ expected: [SIMD4<UInt8>], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.count == expected.count, sourceLocation: sourceLocation)
        for (index, pair) in zip(actual, expected).enumerated() {
            for channel in 0..<4 {
                #expect(abs(Int(pair.0[channel]) - Int(pair.1[channel])) <= 1,
                        "probe \(index), channel \(channel), actual \(pair.0), expected \(pair.1)", sourceLocation: sourceLocation)
            }
        }
    }
}
#endif
