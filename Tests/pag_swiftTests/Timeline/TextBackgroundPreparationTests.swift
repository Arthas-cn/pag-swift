import Testing
@testable import pag_swift

/// 文字背景几何必须计入空白宽度，并保留上游逐行外扩、取整和统一圆角规则。
struct TextBackgroundPreparationTests {
    /// 行内空格虽无绘制轮廓，背景仍覆盖完整推进量，且先于字形组成一块圆角几何。
    @Test func whitespaceExtendsRoundedBackground() throws {
        let style = try PAGText(text: "A ", fontSize: 20,
                                fillColor: PAGColor(red: 1, green: 1, blue: 1))
        let source = SourceText(style: style, baselineShift: 0, firstBaseline: 0,
            isBoxText: false, boxPosition: .zero, boxSize: .zero, fauxBold: false,
            fauxItalic: false, strokeOverFill: true, justification: 0,
            backgroundColor: .defaultFill, backgroundAlpha: 255, direction: 0)
        let layout = TextLayoutResult(glyphs: [
            TextGlyphPlacement(glyphIndex: 0, position: .zero),
            TextGlyphPlacement(glyphIndex: 1, position: ScenePoint(x: 10, y: 0))],
            lines: [TextLayoutLine(glyphRange: 0..<2, advance: 20, baseline: 0)],
            glyphScale: 1, bounds: nil)
        let bounds = TextLayoutBounds(left: 0, top: -8, right: 10, bottom: 2)
        let metrics = [TextBackgroundGlyph(bounds: bounds, matrix: .identity, advance: 10),
            TextBackgroundGlyph(bounds: bounds, matrix: try .translation(x: 10, y: 0), advance: 10)]
        let text = PreparedTextLayer(source: SourceLayerReference(composition: 0, layer: 0),
            style: style, glyphs: [], passes: [], layout: layout, layoutAdvances: [10, 10],
            backgroundGlyphs: metrics, fonts: [], missingGlyphIndices: [], estimatedBytes: 0)
        var budget = FramePlanBudget(limit: 65_536)
        let geometry = try #require(TextBackgroundPreparation.prepare(text: text, source: source, budget: &budget))
        #expect(geometry.contours.count == 1)
        guard case .rectangle(let rect) = geometry.contours[0] else {
            Issue.record("背景应保留圆角矩形轮廓")
            return
        }
        #expect(rect.left == -8 && rect.top == -16)
        #expect(rect.right == 28 && rect.bottom == 10)
        #expect(abs(rect.radius - 26.0 / 3) < 0.0001)
    }
}
