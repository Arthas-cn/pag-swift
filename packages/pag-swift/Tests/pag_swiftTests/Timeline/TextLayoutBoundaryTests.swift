import Testing
@testable import pag_swift

/// 排版拒绝不可表示输入、限制后台工作并响应取消；失败不会被包装成成功的空布局。
struct TextLayoutBoundaryTests {
    /// 框文本必须具有正尺寸和正有效行距；这些尚无可用有限语义的源输入明确 unsupported。
    @Test func unsupportedBoxValuesFailExplicitly() throws {
        #expect(throws: PAGError.unsupportedFeature("textBoxDimensions")) {
            try run(source: source(box: ScenePoint(x: 0, y: 10)))
        }
        #expect(throws: PAGError.unsupportedFeature("textBoxDimensions")) {
            try run(source: source(box: ScenePoint(x: 10, y: -1)))
        }
        #expect(throws: PAGError.unsupportedFeature("textBoxLeading")) {
            try run(source: source(box: ScenePoint(x: 10, y: 10), leading: -1))
        }
        #expect(throws: PAGError.unsupportedFeature("textBoxLeading")) {
            try run(source: source(box: ScenePoint(x: 10, y: 10), fontSize: 0.01))
        }
    }

    /// Double 公开值转 Float、字体指标、逻辑边界及中间累积都必须有限。
    @Test func invalidNumericValuesDoNotEscapeAsPositions() throws {
        #expect(throws: SceneValidator.invalid("unrepresentableTextLayout")) {
            try run(source: source(fontSize: .greatestFiniteMagnitude))
        }
        #expect(throws: SceneValidator.invalid("unrepresentableTextLayout")) {
            try run(glyphs: [glyph(advance: .infinity)])
        }
        #expect(throws: SceneValidator.invalid("unrepresentableTextLayout")) {
            try run(glyphs: [glyph(advance: .greatestFiniteMagnitude), glyph(advance: .greatestFiniteMagnitude)])
        }
        #expect(throws: SceneValidator.invalid("missingTextMetrics")) {
            try run(glyphs: [TextGlyphMetrics(advance: 10, ascent: 0, descent: 0,
                                             bounds: TextLayoutBounds(left: 0, top: 0, right: 10, bottom: 0), isLineBreak: false)])
        }
        #expect(throws: SceneValidator.invalid("unrepresentableTextLayout")) {
            try run(glyphs: [TextGlyphMetrics(advance: 10, ascent: -8, descent: 2,
                                             bounds: TextLayoutBounds(left: 10, top: -8, right: 0, bottom: 2), isLineBreak: false)])
        }
    }

    /// 输出预留内存和候选遍历分别计费，低工作预算不能用近似字号绕过。
    @Test func memoryAndWorkLimitsFailBeforePublishingLayout() throws {
        #expect(throws: PAGError.resourceLimitExceeded("maximumPreparedSceneBytes")) { try run(maximumBytes: 1) }
        #expect(throws: PAGError.resourceLimitExceeded("maximumTextLayoutWork")) { try run(maximumWork: 1) }
        #expect(throws: PAGError.invalidArgument("maximumTextLayoutWork")) { try run(maximumWork: 0) }
        #expect(throws: PAGError.resourceLimitExceeded("maximumTextLayoutWork")) {
            try run(source: source(box: ScenePoint(x: 1, y: 1), fontSize: 1000), maximumWork: 16)
        }
    }

    /// 极大 Float 字号减1可能不变；遇到失败候选立即报资源限制，不能无限循环。
    @Test func fontSizeThatCannotDecrementHasBoundedFailure() throws {
        #expect(throws: PAGError.resourceLimitExceeded("maximumTextLayoutWork")) {
            try run(source: source(box: ScenePoint(x: 1, y: 1), fontSize: 100_000_000))
        }
    }

    /// 取消的后台准备即使输入合法也不生成可发布的排版结果，不依赖 sleep 或主 actor。
    @Test func cancelledBackgroundLayoutThrowsCancellation() async throws {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try run()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 合法整形指标默认提供两个 glyph，确保框不足时必须考虑换行。
    private func glyph(advance: Float = 10) -> TextGlyphMetrics {
        TextGlyphMetrics(advance: advance, ascent: -8, descent: 2,
                         bounds: TextLayoutBounds(left: 0, top: -8, right: 10, bottom: 2), isLineBreak: false)
    }

    /// 只变更边界测试需要的框、字号和行距，不借语义夹具宣称 PAG 字节行为。
    private func source(box: ScenePoint? = nil, fontSize: Double = 10, leading: Double = 0) throws -> SourceText {
        let style = try PAGText(text: "AB", fontSize: fontSize, leading: leading)
        return SourceText(style: style, baselineShift: 0, firstBaseline: 0, isBoxText: box != nil,
                          boxPosition: .zero, boxSize: box ?? .zero, fauxBold: false, fauxItalic: false,
                          strokeOverFill: true, justification: 0, backgroundColor: SceneColor(red: 0, green: 0, blue: 0),
                          backgroundAlpha: 0, direction: 0)
    }

    /// 在可注入的两种限制下调用真实排版器，异常直接交给测试检查。
    private func run(source value: SourceText? = nil, glyphs: [TextGlyphMetrics]? = nil,
                     maximumBytes: Int = 64 * 1024 * 1024, maximumWork: Int = 4_194_304) throws -> TextLayoutResult {
        let input = try value ?? source()
        var budget = FramePlanBudget(limit: maximumBytes, resourceName: "maximumPreparedSceneBytes")
        return try TextLayout.layout(glyphs ?? [glyph(), glyph()], source: input, style: input.style,
                                     budget: &budget, maximumWork: maximumWork)
    }
}
