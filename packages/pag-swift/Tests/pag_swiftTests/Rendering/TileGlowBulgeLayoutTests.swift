import Foundation
import Testing
@testable import pag_swift

/// 层115完整平铺域与实际可见采样域的保守包含性，避免逐效果借3倍整域纹理。
struct TileGlowBulgeLayoutTests {
    /// 真实尺寸与半尺寸均保留完整语义域，但GPU工作矩形小于300%全域。
    @Test(arguments: [1.0, 0.5])
    func realClip1ScaleKeepsVisibleWorkBounded(_ scale: Double) throws {
        let source = try PAGSize(width: 720, height: 1280)
        let clip = FrameClip(size: source, matrix: try .scale(x: scale, y: scale))
        let sampled = SampledMotionTile(center: ScenePoint(x: 360, y: 640),
            tileWidth: 62, tileHeight: 62, outputWidth: 300, outputHeight: 300,
            mirrorEdges: true, phase: 0, horizontalPhaseShift: false)
        let tile = try FrameMotionTile(sampled, compositionSize: source)
        let glow = SampledGlow(threshold: 1, radius: 48, intensity: 1)
        let bulge = SampledBulge(horizontalRadius: 396, verticalRadius: 636,
            center: ScenePoint(x: 360, y: 640), height: -0.57, pinning: true)
        let visible = try RenderBounds(left: 0, top: 0,
            right: 720 * scale, bottom: 1280 * scale)
        let layout = try #require(try TileGlowBulgeLayout(clip: clip, tile: tile,
            glow: glow, bulge: bulge, visible: visible))
        #expect(layout.tileBounds.left == -720 * scale)
        #expect(layout.tileBounds.top == -1280 * scale)
        #expect(layout.output.width == Int(720 * scale))
        #expect(layout.output.height == Int(1280 * scale))
        #expect(layout.sample.width < Int(1200 * scale) + 8)
        #expect(layout.sample.height < Int(1800 * scale) + 8)
        #expect(layout.sample.bounds.left <= layout.glowOutput.bounds.left)
        #expect(layout.sample.bounds.top <= layout.glowOutput.bounds.top)
        #expect(layout.sample.bounds.right >= layout.glowOutput.bounds.right)
        #expect(layout.sample.bounds.bottom >= layout.glowOutput.bounds.bottom)

        let fullWidth = 2160 * scale, fullHeight = 3840 * scale
        let center = SIMD2(0.5, 0.5)
        let radius = SIMD2(396.0 / 2160, 636.0 / 3840)
        for x in stride(from: 0.5 * scale, to: 720 * scale, by: 16 * scale) {
            for y in stride(from: 0.5 * scale, to: 1280 * scale, by: 16 * scale) {
                // 与上游Bulge片元相同的逆映，用网格验证布局确实覆盖全部潜在源点及Glow邻域。
                var target = SIMD2((x - layout.tileBounds.left) / fullWidth,
                                   (y - layout.tileBounds.top) / fullHeight)
                let point = target - center
                let distance = pow(point.x / radius.x, 2) + pow(point.y / radius.y, 2)
                if distance <= 1 {
                    let length = sqrt(point.x * point.x + point.y * point.y)
                    let angle = atan2(length, sqrt(1 - sqrt(length))) / Double.pi
                    let weight = (1 - distance) * angle
                    let direction = length == 0 ? SIMD2<Double>.zero : point / length
                    target = target - bulge.height * weight * direction
                }
                let sampledX = layout.tileBounds.left + target.x * fullWidth
                let sampledY = layout.tileBounds.top + target.y * fullHeight
                #expect(sampledX - 4 >= layout.sample.bounds.left)
                #expect(sampledX + 4 <= layout.sample.bounds.right)
                #expect(sampledY - 4 >= layout.sample.bounds.top)
                #expect(sampledY + 4 <= layout.sample.bounds.bottom)
            }
        }
    }

    /// 无显示交集或无法证明椭圆位移时不建立附件，也不把不安全范围猜成整帧。
    @Test func absentAndUnboundedInputsStayClosed() throws {
        let source = try PAGSize(width: 720, height: 1280)
        let clip = FrameClip(size: source, matrix: .identity)
        let tile = try FrameMotionTile(SampledMotionTile(center: ScenePoint(x: 360, y: 640),
            tileWidth: 62, tileHeight: 62, outputWidth: 300, outputHeight: 300,
            mirrorEdges: true, phase: 0, horizontalPhaseShift: false), compositionSize: source)
        let glow = SampledGlow(threshold: 1, radius: 0, intensity: 1)
        let bulge = SampledBulge(horizontalRadius: 396, verticalRadius: 636,
            center: ScenePoint(x: 360, y: 640), height: -0.57, pinning: true)
        let outside = try RenderBounds(left: 2000, top: 0, right: 2200, bottom: 200)
        #expect(try TileGlowBulgeLayout(clip: clip, tile: tile, glow: glow,
            bulge: bulge, visible: outside) == nil)
        let unsafe = SampledBulge(horizontalRadius: 2500, verticalRadius: 636,
            center: bulge.center, height: bulge.height, pinning: true)
        let visible = try RenderBounds(left: 0, top: 0, right: 720, bottom: 1280)
        #expect(throws: PAGError.unsupportedFeature("tileGlowBulgeBounds")) {
            _ = try TileGlowBulgeLayout(clip: clip, tile: tile,
                glow: glow, bulge: unsafe, visible: visible)
        }
    }
}
