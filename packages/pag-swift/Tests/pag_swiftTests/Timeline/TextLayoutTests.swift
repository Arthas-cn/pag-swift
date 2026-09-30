import Testing
@testable import pag_swift

/// 独立字形指标驱动的 PAG 排版数值测试；不把模拟指标当成真实字体或显示验收。
struct TextLayoutTests {
    /// tracking 使用千分之一字号并四舍五入；显式 leading 与基线偏移各保留源单位。
    @Test func pointTextUsesPAGTrackingLeadingAndBaselineShift() throws {
        let style = try PAGText(text: "AB\nC", fontSize: 10, leading: 20, tracking: 150)
        let result = try layout([glyph(), glyph(), newline(), glyph()], style: style, baselineShift: 3)
        #expect(result.glyphs.map(\.glyphIndex) == [0, 1, 3])
        #expect(result.glyphs.map(\.position) == [ScenePoint(x: 0, y: -3), ScenePoint(x: 12, y: -3), ScenePoint(x: 0, y: 17)])
        #expect(result.lines.map(\.advance) == [22, 10])
        #expect(result.bounds == TextLayoutBounds(left: 0, top: -11, right: 22, bottom: 19))
        #expect(result.glyphScale == 1)
    }

    /// 七个源对齐编码在点文本中只有普通居中和右对齐改变行首，FullJustify 无框时不拉伸。
    @Test(arguments: UInt8(0)...UInt8(6)) func pointJustificationHasNoImplicitBox(_ justification: UInt8) throws {
        let result = try layout([glyph(), glyph()], justification: justification)
        let first: Double = justification == 1 ? -10 : (justification == 2 ? -20 : 0)
        #expect(result.glyphs.map(\.position.x) == [first, first + 10])
    }

    /// 显式空行占据自动行距，末尾换行只结束当前行，不凭空追加一行。
    @Test func emptyLinesHaveBoundsAndTrailingBreakDoesNotAddLine() throws {
        let result = try layout([glyph(), newline(), newline(), glyph(), newline()])
        #expect(result.lines.count == 3)
        #expect(result.lines.map(\.glyphRange) == [0..<1, 1..<1, 1..<2])
        #expect(result.glyphs.map(\.glyphIndex) == [0, 3])
        #expect(result.glyphs.map(\.position.y) == [0, 24])
        #expect(result.bounds == TextLayoutBounds(left: 0, top: -8, right: 10, bottom: 26))
        let emptyLine = try layout([newline()])
        let bounds = try #require(emptyLine.bounds)
        #expect(emptyLine.glyphs.isEmpty && emptyLine.lines.count == 1)
        #expect(bounds.left == 0 && bounds.right == 1)
        #expect(abs(bounds.top + 9.6) < 0.00001 && abs(bounds.bottom - 2.4) < 0.00001)
    }

    /// 空 glyph 输入不计算 ascent/descent 的零分母，也不生成空背景或假字形。
    @Test func emptyInputReturnsEmptyLayout() throws {
        let result = try layout([])
        #expect(result.glyphs.isEmpty && result.lines.isEmpty && result.bounds == nil)
        #expect(result.glyphScale == 1)
    }

    /// 框只有一行空间时四个10宽 glyph 在字号6首次容纳，基线偏移不随0.6缩放。
    @Test func boxFittingUsesWholeFontSizeStepsAndUnscaledBaselineShift() throws {
        let result = try layout(Array(repeating: glyph(), count: 4), box: ScenePoint(x: 25, y: 12),
                                firstBaseline: 10, baselineShift: 2)
        #expect(abs(result.glyphScale - 0.6) < 0.000001)
        #expect(result.lines.count == 1)
        for (index, placement) in result.glyphs.enumerated() {
            #expect(abs(placement.position.x - Double(index * 6)) < 0.00001)
            #expect(abs(placement.position.y - 6.56) < 0.00001)
        }
        #expect(abs(try #require(result.bounds).bottom - 7.76) < 0.00001)
    }

    /// 框排版保留源坐标，行数不足时纵向居中；末行的左右中与 FullJustify 编码不能混淆。
    @Test(arguments: UInt8(0)...UInt8(6)) func boxJustificationAndVerticalCentering(_ justification: UInt8) throws {
        let result = try layout([glyph(), glyph()], justification: justification, box: ScenePoint(x: 50, y: 50),
                                position: ScenePoint(x: 100, y: 200), firstBaseline: 208)
        let starts: [Double] = [0, 15, 30, 0, 30, 15, 0]
        let first = 100 + starts[Int(justification)]
        #expect(result.glyphScale == 1)
        #expect(result.glyphs.map(\.position.x) == [first, first + (justification == 6 ? 40 : 10)])
        #expect(result.glyphs.map(\.position.y) == [226, 226])
    }

    /// FullJustify 只拉伸非末行；自动换行与显式换行的末行判定不同。
    @Test(arguments: UInt8(3)...UInt8(6)) func fullJustificationDistinguishesWrappedAndHardBreaks(_ justification: UInt8) throws {
        let wrapped = try layout(Array(repeating: glyph(), count: 5), justification: justification,
                                 box: ScenePoint(x: 35, y: 40), firstBaseline: 8)
        #expect(wrapped.lines.count == 2 && wrapped.glyphScale == 1)
        #expect(Array(wrapped.glyphs.prefix(3)).map(\.position.x) == [0, 12.5, 25])
        let starts: [UInt8: Double] = [3: 0, 4: 15, 5: 7.5, 6: 0]
        let first = try #require(starts[justification])
        #expect(Array(wrapped.glyphs.suffix(2)).map(\.position.x) == [first, first + (justification == 6 ? 25 : 10)])
        let hard = try layout([glyph(), glyph(), newline(), glyph()], justification: justification,
                              box: ScenePoint(x: 35, y: 40), firstBaseline: 8)
        #expect(Array(hard.glyphs.prefix(2)).map(\.position.x) == [first, first + (justification == 6 ? 25 : 10)])
    }

    /// FullJustify 的单项与空行没有可分配的相邻间距，所有输出必须有限。
    @Test func singleGlyphAndEmptyFullJustifyLineAvoidDivisionByZero() throws {
        let result = try layout([newline(), glyph()], justification: 6, box: ScenePoint(x: 30, y: 40), firstBaseline: 8)
        #expect(result.lines.count == 2 && result.lines[0].glyphRange.isEmpty)
        let placement = try #require(result.glyphs.first)
        #expect(placement.position.x == 0 && placement.position.y.isFinite)
        try #require(result.bounds).validate()
    }

    /// 断行至少消费一项，即使单字比框宽也不会无进展；baseline 在框底内时不额外剪字形边缘。
    @Test func wideGlyphAndBoundsOutsideBoxRemainRepresentable() throws {
        let wide = glyph(advance: 100)
        let result = try layout([wide], box: ScenePoint(x: 10, y: 12), firstBaseline: 10)
        #expect(result.glyphScale == 1 && result.glyphs.count == 1)
        let bounds = try #require(result.bounds)
        #expect(bounds.right == 100 && bounds.bottom == 12)
        let low = try layout([glyph(bounds: TextLayoutBounds(left: 0, top: -8, right: 10, bottom: 20))],
                             box: ScenePoint(x: 10, y: 12), firstBaseline: 10)
        #expect(try #require(low.bounds).bottom == 30)
    }

    /// 负 tracking 可产生重叠，点文本负 leading 可向上排下一行；不擅自钳成零。
    @Test func negativeTrackingAndPointLeadingArePreserved() throws {
        let style = try PAGText(text: "AB\nC", fontSize: 10, leading: -5, tracking: -150)
        let result = try layout([glyph(), glyph(), newline(), glyph()], style: style)
        #expect(result.glyphs.map(\.position) == [ScenePoint(x: 0, y: 0), ScenePoint(x: 8, y: 0), ScenePoint(x: 0, y: -5)])
    }

    /// 竖排只映射布局位置：点文本向左换行，框文本以原框右边缘建立首基线。
    @Test func verticalPositionsUseSwappedBoxAndRightEdgeOrigin() throws {
        let point = try layout([glyph(), glyph(), newline(), glyph()], direction: 2)
        #expect(point.glyphs.map(\.position) == [ScenePoint(x: 0, y: 0), ScenePoint(x: 0, y: 10), ScenePoint(x: -12, y: 0)])
        let box = try layout([glyph(), glyph()], box: ScenePoint(x: 20, y: 40), position: ScenePoint(x: 100, y: 200),
                             firstBaseline: 112, direction: 2)
        #expect(box.glyphs.map(\.position) == [ScenePoint(x: 106, y: 200), ScenePoint(x: 106, y: 210)])
        #expect(box.bounds == TextLayoutBounds(left: 104, top: 200, right: 114, bottom: 220))
    }

    /// 源算法对不大于5的字号不搜索候选，保留其纵向居中规则而非自行改成系统排版。
    @Test func smallSourceFontDoesNotRunCandidateSearch() throws {
        let style = try PAGText(text: "A", fontSize: 4)
        let result = try layout([glyph()], style: style, box: ScenePoint(x: 20, y: 20), firstBaseline: 2)
        #expect(result.glyphScale == 1 && result.glyphs.first?.position.y == 12)
    }

    /// 逐次减字号到5后停止搜索；仍放不下的后续行按 baseline 越界规则省略，不继续无限缩小。
    @Test func minimumCandidateKeepsOnlyLinesWhoseBaselineFits() throws {
        let style = try PAGText(text: "AB", fontSize: 6)
        let result = try layout([glyph(), glyph()], style: style, box: ScenePoint(x: 1, y: 1))
        #expect(abs(result.glyphScale - Float(5) / 6) < 0.000001)
        #expect(result.lines.count == 1 && result.glyphs.map(\.glyphIndex) == [0])
        #expect(abs(try #require(result.glyphs.first).position.y + 0.3766667) < 0.00001)
    }

    /// 输入指标仅代表一个普通可见 glyph；调整 advance 时同步给出相同宽度的逻辑范围。
    private func glyph(advance: Float = 10, bounds: TextLayoutBounds? = nil) -> TextGlyphMetrics {
        TextGlyphMetrics(advance: advance, ascent: -8, descent: 2,
                         bounds: bounds ?? TextLayoutBounds(left: 0, top: -8, right: advance, bottom: 2), isLineBreak: false)
    }

    /// 换行符保留有效字体指标，零 advance/零面积，避免测试依赖平台字体选择。
    private func newline() -> TextGlyphMetrics {
        TextGlyphMetrics(advance: 0, ascent: -8, descent: 2,
                         bounds: TextLayoutBounds(left: 0, top: 0, right: 0, bottom: 0), isLineBreak: true)
    }

    /// 从独立语义参数构造源文本；未测试的绘制属性固定为默认，避免伪造二进制证据。
    private func layout(_ glyphs: [TextGlyphMetrics], style: PAGText? = nil, justification: UInt8 = 0,
                        box: ScenePoint? = nil, position: ScenePoint = .zero, firstBaseline: Double = 0,
                        baselineShift: Double = 0, direction: UInt8 = 0) throws -> TextLayoutResult {
        let value = try style ?? PAGText(text: "指标夹具", fontSize: 10)
        let source = SourceText(style: value, baselineShift: baselineShift, firstBaseline: firstBaseline,
                                isBoxText: box != nil, boxPosition: position, boxSize: box ?? .zero,
                                fauxBold: false, fauxItalic: false, strokeOverFill: true, justification: justification,
                                backgroundColor: SceneColor(red: 0, green: 0, blue: 0), backgroundAlpha: 0, direction: direction)
        var budget = FramePlanBudget(limit: 64 * 1024 * 1024, resourceName: "maximumPreparedSceneBytes")
        return try TextLayout.layout(glyphs, source: source, style: value, budget: &budget)
    }
}
