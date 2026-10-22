import Foundation
import Testing
@testable import pag_swift

/// 逐帧文字动画只改矩阵与alpha，保留一次整形所得的轮廓和逻辑行。
struct TextAnimatorPreparationTests {
    /// 空白glyph虽没有轮廓仍参与字距；中心对齐后可见字形分居两侧。
    @Test func trackingCountsWhitespaceAndAppliesPerGlyphOpacity() throws {
        let (base, source) = try text(direction: 0, justification: 1)
        let animator = animation(tracking: 10, position: ScenePoint(x: 2, y: 3),
            scale: ScenePoint(x: 2, y: 1), opacity: 128)
        var budget = FramePlanBudget(limit: 65_536)
        let result = try TextAnimatorPreparation.prepare(base: base, source: source,
            animators: [animator], at: 0, budget: &budget)
        let first = try #require(result.glyphs.first(where: { $0.layoutIndex == 0 }))
        let last = try #require(result.glyphs.first(where: { $0.layoutIndex == 2 }))
        #expect(abs(first.matrix.tx - -8) < 0.0001)
        #expect(abs(last.matrix.tx - 32) < 0.0001)
        #expect(first.matrix.ty == 3 && last.matrix.ty == 3)
        #expect(first.matrix.a == 2 && last.matrix.a == 2)
        #expect(abs(first.alpha - 128.0 / 255) < 0.0001)
        #expect(result.glyphs[0].fill === base.glyphs[0].fill)
    }

    /// 竖排字距沿y而非x，图层基线位置仍由原布局提供。
    @Test func verticalTrackingMovesOnlyY() throws {
        let (base, source) = try text(direction: 2, justification: 0)
        var budget = FramePlanBudget(limit: 65_536)
        let result = try TextAnimatorPreparation.prepare(base: base, source: source,
            animators: [animation(tracking: 10)], at: 0, budget: &budget)
        let first = try #require(result.glyphs.first(where: { $0.layoutIndex == 0 }))
        let last = try #require(result.glyphs.first(where: { $0.layoutIndex == 2 }))
        #expect(first.matrix.tx == 0 && last.matrix.tx == 20)
        #expect(first.matrix.ty == 0 && last.matrix.ty == 20)
    }

    /// 两个动画器按源顺序累乘alpha，不以后一项覆盖前一项。
    @Test func successiveOpacityAnimatorsMultiply() throws {
        let (base, source) = try text(direction: 0, justification: 0)
        var budget = FramePlanBudget(limit: 65_536)
        let result = try TextAnimatorPreparation.prepare(base: base, source: source,
            animators: [animation(opacity: 128), animation(opacity: 128)], at: 0, budget: &budget)
        #expect(abs(result.glyphs[0].alpha - pow(128.0 / 255, 2)) < 0.0001)
    }

    /// 不够容纳逐字形表的预算在分配前失败，不影响原准备资源。
    @Test func preparationBudgetDoesNotPublishPartialGlyphs() throws {
        let (base, source) = try text(direction: 0, justification: 0)
        var budget = FramePlanBudget(limit: 128)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try TextAnimatorPreparation.prepare(base: base, source: source,
                animators: [animation(tracking: 10)], at: 0, budget: &budget)
        }
        #expect(base.glyphs.count == 2)
    }

    /// 构造一行三个位置，其中中间空格只存在于布局，不生成绘制轮廓。
    private func text(direction: UInt8, justification: UInt8) throws -> (PreparedTextLayer, SourceText) {
        let style = try PAGText(text: "A B", fontSize: 20, fillColor: PAGColor(red: 1, green: 1, blue: 1))
        let source = SourceText(style: style, baselineShift: 0, firstBaseline: 0, isBoxText: false,
            boxPosition: .zero, boxSize: .zero, fauxBold: false, fauxItalic: false,
            strokeOverFill: true, justification: justification, backgroundColor: .defaultFill,
            backgroundAlpha: 0, direction: direction)
        let outline = GlyphOutline(elements: [.move(.zero), .line(ScenePoint(x: 1, y: 0)),
                                              .line(ScenePoint(x: 1, y: 1)), .close])
        let placements = [TextGlyphPlacement(glyphIndex: 0, position: .zero),
            TextGlyphPlacement(glyphIndex: 1, position: ScenePoint(x: 10, y: 0)),
            TextGlyphPlacement(glyphIndex: 2, position: ScenePoint(x: 20, y: 0))]
        let layout = TextLayoutResult(glyphs: placements,
            lines: [TextLayoutLine(glyphRange: 0..<3, advance: 30, baseline: 0)], glyphScale: 1, bounds: nil)
        let glyphs = [PreparedTextGlyph(fill: outline, stroke: nil, matrix: .identity,
            alpha: 1, layoutIndex: 0, advance: 10, fontIndex: 0, cluster: 0..<1),
            PreparedTextGlyph(fill: outline, stroke: nil, matrix: try .translation(x: 20, y: 0),
            alpha: 1, layoutIndex: 2, advance: 10, fontIndex: 0, cluster: 2..<3)]
        let prepared = PreparedTextLayer(source: SourceLayerReference(composition: 0, layer: 0),
            style: style, glyphs: glyphs, passes: [.fill(try PAGColor(red: 1, green: 1, blue: 1))],
            layout: layout, layoutAdvances: [10, 10, 10], fonts: [], missingGlyphIndices: [],
            estimatedBytes: 1024)
        return (prepared, source)
    }

    /// 构造只有指定排版效果的动画器，其余字段缺席而非编码默认值。
    private func animation(tracking: Double? = nil, position: ScenePoint? = nil,
                           scale: ScenePoint? = nil, opacity: UInt8? = nil) -> SourceTextAnimator {
        SourceTextAnimator(selectors: [], trackingType: nil,
            trackingAmount: tracking.map { SourceProperty(constant: $0) },
            fillColor: nil, strokeColor: nil,
            position: position.map { SourceProperty(constant: $0) },
            scale: scale.map { SourceProperty(constant: $0) }, rotation: nil,
            opacity: opacity.map { SourceProperty(constant: $0) })
    }
}
