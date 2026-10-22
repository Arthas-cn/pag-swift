import Testing
@testable import pag_swift

/// 文字路径把同层mask、普通整形和逐帧字形矩阵接入正式帧计划的语义回归。
struct TextPathFramePlanTests {
    /// 水平开放线平移字形基线，原轮廓复用且不申请普通静态Text Picture。
    @Test func pathPositionsGlyphsWithoutReshaping() async throws {
        let text = try TextFixtures.source("AA")
        let path = try SourcePath(verbs: [.move, .line],
            points: [ScenePoint(x: 20, y: 30), ScenePoint(x: 80, y: 30)])
        let layer = SceneFixtures.layer(1, content: .text(text), masks: [mask(path)], textPath: option())
        let file = try SceneFixtures.build([SceneFixtures.composition(1, layers: [layer])])
        let scene = try await PreparedScene.prepare(file.composition)
        let reference = SourceLayerReference(composition: 0, layer: 0)
        let base = try #require(scene.texts[reference])
        let frame = try await FramePlanner.prepare(scene, at: .zero,
            targetSize: file.composition.size, scale: 1, mode: .none)
        let mapped = try #require(frame.texts.values.first)
        #expect(mapped !== base && mapped.glyphs.count == base.glyphs.count)
        #expect(mapped.glyphs[0].fill === base.glyphs[0].fill)
        #expect(abs(mapped.glyphs[0].matrix.tx - base.glyphs[0].matrix.tx - 20) < 0.01)
        #expect(abs(mapped.glyphs[0].matrix.ty - base.glyphs[0].matrix.ty - 30) < 0.01)
        #expect(!frame.plan.commands.contains { if case .beginPicture = $0 { true } else { false } })
    }

    /// 同一源文字在不同合成帧采样动态mask路径，字形资源代数和位置必须随帧改变。
    @Test func animatedMaskPathChangesGlyphPlacement() async throws {
        let first = try SourcePath(verbs: [.move, .line],
            points: [ScenePoint(x: 0, y: 10), ScenePoint(x: 100, y: 10)])
        let last = try SourcePath(verbs: [.move, .line],
            points: [ScenePoint(x: 0, y: 40), ScenePoint(x: 100, y: 40)])
        let property = try SourceProperty(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 20,
            startValue: first, endValue: last, easing: .linear, spatialCurve: nil)])
        let sourceMask = SourceMask(id: 1, isInverted: false, mode: .none, path: property,
            feather: nil, opacity: SourceProperty(constant: 255), expansion: SourceProperty(constant: 0))
        let layer = SceneFixtures.layer(1, content: .text(try TextFixtures.source("A")),
            masks: [sourceMask], textPath: option())
        let file = try SceneFixtures.build([SceneFixtures.composition(1, layers: [layer])])
        let scene = try await PreparedScene.prepare(file.composition)
        let zero = try await FramePlanner.prepare(scene, at: .zero,
            targetSize: file.composition.size, scale: 1, mode: .none)
        let later = try await FramePlanner.prepare(scene, at: PAGTime(microseconds: 500_000),
            targetSize: file.composition.size, scale: 1, mode: .none)
        let a = try #require(zero.texts.values.first), b = try #require(later.texts.values.first)
        #expect(a.identity != b.identity)
        #expect(abs(a.glyphs[0].matrix.ty - 10) < 0.01)
        #expect(abs(b.glyphs[0].matrix.ty - 32.5) < 0.1)
    }

    /// 创建不会参加普通裁剪的同层mask；tag69仍可按ID引用它的路径。
    private func mask(_ path: SourcePath) -> SourceMask {
        SourceMask(id: 1, isInverted: false, mode: .none, path: SourceProperty(constant: path),
            feather: nil, opacity: SourceProperty(constant: 255), expansion: SourceProperty(constant: 0))
    }

    /// 常量文字路径选默认方向和边距，测试专注实际glyph位置。
    private func option() -> SourceTextPathOption {
        SourceTextPathOption(maskID: 1, reversed: SourceProperty(constant: false),
            perpendicular: SourceProperty(constant: true), forceAlignment: SourceProperty(constant: false),
            firstMargin: SourceProperty(constant: 0), lastMargin: SourceProperty(constant: 0))
    }
}
