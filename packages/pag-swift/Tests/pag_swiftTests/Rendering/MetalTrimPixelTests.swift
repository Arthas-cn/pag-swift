#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// Trim最终写入真实窗口drawable的独立像素断言；只在测试通路读取少量像素。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要Metal设备"), .timeLimit(.minutes(1)))
struct MetalTrimPixelTests {
    /// 同一挂载目标覆盖Fill/Gradient/Stroke、cap/join/dash、多轮廓、接缝、曲线与透明组。
    @MainActor @Test func trimDrawsIntoMountedDrawable() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 180, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · Trim"
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
            try await fills(owner, target)
            try await endpointsAndJoins(owner, target)
            try await dashesAndContours(owner, target)
            try await groups(owner, target)
            #expect(!target.mailbox.snapshot.hasLease)
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// 半方形缺失左下三角形；区间/颜色动画往返后清除旧画面，Conic半圆覆盖右侧。
    private func fills(_ owner: MetalStrokePixelOwner, _ target: MetalStrokePixelTarget) async throws {
        for (animateColor, animateRange) in [(false, false), (true, false), (false, true)] {
            let scene = try await MetalStrokeFixtures.scene(MetalTrimFixtures.filled(animatedColor: animateColor, animatedRange: animateRange))
            for frame: Int64 in [0, 10, 0] {
                let color = animateColor && frame == 10 ? SIMD4<UInt8>(0, 0, 255, 255) : red
                expect(try await owner.pixels(ShapePathFixtures.plan(scene, at: frame), target: target,
                    at: [SIMD2(60, 30), SIMD2(30, 60), SIMD2(5, 5)]), [color, animateRange && frame == 10 ? color : .zero, .zero])
            }
        }
        for kind in [SourceGradientKind.linear, .radial] {
            let scene = try await MetalStrokeFixtures.scene(MetalTrimFixtures.filled(gradient: kind))
            // 像素中心减材料起点为(40,-20)；裁剪只改覆盖，不能缩放渐变坐标。
            let t = kind == .linear ? 40.0 / 60 : (40.0 * 40 + 20.0 * 20).squareRoot() / 60
            expect(try await owner.pixels(ShapePathFixtures.plan(scene, at: 0), target: target,
                at: [SIMD2(60, 30), SIMD2(30, 60)]), [gradient(t), .zero])
        }
        let circle = try await MetalStrokeFixtures.scene(MetalTrimFixtures.ellipse())
        expect(try await owner.pixels(ShapePathFixtures.plan(circle, at: 0), target: target,
            at: [SIMD2(60, 50), SIMD2(40, 50), SIMD2(90, 50)]), [red, .zero, .zero])
    }

    /// 截取端点仍使用cap；接缝的两个Move不能焊成miter；L形外角分别验证三种join。
    private func endpointsAndJoins(_ owner: MetalStrokePixelOwner, _ target: MetalStrokePixelTarget) async throws {
        for cap in [SourceLineCap.butt, .round, .square] {
            let scene = try await MetalStrokeFixtures.scene(MetalTrimFixtures.line(start: 1.0 / 3, end: 2.0 / 3, cap: cap, width: 12))
            // 半径6时(35...36,45...46)整像素都在圆头外、方头内，避免把边缘部分覆盖误当透明。
            expect(try await owner.pixels(ShapePathFixtures.plan(scene, at: 0), target: target,
                at: [SIMD2(50, 50), SIMD2(35, 50), SIMD2(35, 45)]),
                [red, cap == .butt ? .zero : red, cap == .square ? red : .zero])
        }
        for join in [SourceLineJoin.miter, .round, .bevel] {
            let scene = try await MetalStrokeFixtures.scene(MetalTrimFixtures.squareStroke(start: 0, end: 0.5, join: join))
            expect(try await owner.pixels(ShapePathFixtures.plan(scene, at: 0), target: target,
                at: [SIMD2(50, 20), SIMD2(80, 50), SIMD2(84, 16), SIMD2(83, 17), SIMD2(50, 50)]),
                [red, red, join == .miter ? red : .zero, join == .bevel ? .zero : red, .zero])
        }
        for cap in [SourceLineCap.butt, .round] {
            let scene = try await MetalStrokeFixtures.scene(MetalTrimFixtures.squareStroke(start: 0.75, end: 1.25, cap: cap))
            expect(try await owner.pixels(ShapePathFixtures.plan(scene, at: 0), target: target,
                at: [SIMD2(20, 50), SIMD2(50, 20), SIMD2(17, 17), SIMD2(80, 50)]),
                [red, red, cap == .round ? red : .zero, .zero])
        }
    }

    /// 反向裁剪改变dash推进方向而不反转渐变；多轮廓始终只裁剪方向确定后的首个可测轮廓。
    private func dashesAndContours(_ owner: MetalStrokePixelOwner, _ target: MetalStrokePixelTarget) async throws {
        for mode in [SourceTrimMode.simultaneously, .individually] {
            let scene = try await MetalStrokeFixtures.scene(MetalTrimFixtures.batch(mode))
            expect(try await owner.pixels(ShapePathFixtures.plan(scene, at: 0), target: target,
                at: [SIMD2(40, 25), SIMD2(70, 25), SIMD2(30, 75), SIMD2(60, 75)]),
                mode == .simultaneously ? [red, .zero, .zero, red] : [.zero, red, red, .zero])
        }
        for reversed in [false, true] {
            for isGradient in [false, true] {
                let scene = try await MetalStrokeFixtures.scene(MetalTrimFixtures.line(start: reversed ? 0.6 : 0,
                    end: reversed ? 0 : 0.6, dashed: true, gradient: isGradient))
                let xs = [25, 35, 45, 55]
                let expected = xs.enumerated().map { index, x -> SIMD4<UInt8> in
                    let on = reversed ? index % 2 == 1 : index % 2 == 0
                    return on ? (isGradient ? gradient(Double(x - 20) / 60) : red) : .zero
                }
                expect(try await owner.pixels(ShapePathFixtures.plan(scene, at: 0), target: target,
                    at: xs.map { SIMD2($0, 50) }), expected)
            }
            let multiple = try await MetalStrokeFixtures.scene(MetalTrimFixtures.line(start: reversed ? 0.75 : 0.25,
                end: reversed ? 0.25 : 0.75, multipleContours: true))
            expect(try await owner.pixels(ShapePathFixtures.plan(multiple, at: 0), target: target,
                at: [SIMD2(50, 25), SIMD2(50, 75), SIMD2(25, 25)]), reversed ? [.zero, red, .zero] : [red, .zero, .zero])
        }
    }

    /// 两个重叠子paint受父Trim与单次组alpha影响，交叉不能二次叠加alpha或遗留上一帧。
    private func groups(_ owner: MetalStrokePixelOwner, _ target: MetalStrokePixelTarget) async throws {
        let scene = try await MetalStrokeFixtures.scene(MetalTrimFixtures.groupOpacity())
        for frame: Int64 in [0, 5, 10, 0] {
            let alpha: UInt8 = frame == 5 ? 127 : frame == 10 ? 0 : 255
            let color = SIMD4<UInt8>(alpha, 0, 0, alpha)
            expect(try await owner.pixels(ShapePathFixtures.plan(scene, at: frame), target: target,
                at: [SIMD2(25, 25), SIMD2(40, 25), SIMD2(60, 25), SIMD2(15, 50)]), [color, color, color, .zero])
        }
    }

    /// 不透明红色用于远离边缘的覆盖断言。
    private let red = SIMD4<UInt8>(255, 0, 0, 255)

    /// 手算位置对应的red→blue颜色，只做最终字节量化，不复用生产着色器公式。
    private func gradient(_ t: Double) -> SIMD4<UInt8> {
        SIMD4(UInt8(((1 - t) * 255).rounded()), 0, UInt8((t * 255).rounded()), 255)
    }

    /// 允许一字节量化差，失败指出探针及通道；不按实测颜色反写期望。
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
