/// PAG 静态文本的单次排版参数；由源字段与整形指标派生，不在多个任务间共享可变状态。
struct TextLayoutSettings {
    /// 原字号的可表示 Float 值，必须为正。
    let fontSize: Float
    /// 上游 0...6 对齐编码，初始化时校验。
    let justification: UInt8
    /// 是否必须运行框文本适应；点文本的宽高不限制断行。
    let isBox: Bool
    /// 是否把统一横排位置映射为源竖排位置。
    let isVertical: Bool
    /// 统一横排空间中的有效框宽度；点文本使用正无穷作为循环边界。
    let width: Float
    /// 统一横排空间中的框底；点文本使用正无穷作为循环边界。
    let height: Float
    /// 方向映射之后的图层局部水平原点；竖框采用原框右边缘。
    let originX: Float
    /// 方向映射之后的图层局部垂直原点。
    let originY: Float
    /// 源基线偏移；不会随自动缩字号改变。
    let baselineShift: Float
    /// 源首基线或适应后的首基线，位于统一横排空间。
    var firstBaseline: Float
    /// 自动行高按字体 ascent/descent 比例分配的上边界。
    var fontTop: Float
    /// 自动行高按字体 ascent/descent 比例分配的下边界。
    var fontBottom: Float
    /// 已解析自动值的行距；框文本要求正值，点文本可为负。
    var lineGap: Float
    /// PAG tracking 换算成合成坐标并 roundf 后的值，允许负数。
    var tracking: Float
    /// 全部 glyph 的共享正缩放，框适应之前为1。
    var glyphScale: Float = 1

    /// 从非空整形输入建立参数；非法浮点、缺失垂直指标或不可支持的框语义明确失败。
    init(source: SourceText, style: PAGText, glyphs: [TextGlyphMetrics], work: inout TextLayoutWork) throws {
        fontSize = try Self.finite(Float(style.fontSize))
        guard fontSize > 0, source.justification <= 6, source.direction <= 2 else {
            throw SceneValidator.invalid("unrepresentableTextLayout")
        }
        justification = source.justification
        isBox = source.isBoxText
        isVertical = source.direction == 2
        baselineShift = try Self.finite(Float(source.baselineShift))
        lineGap = try Self.finite(style.leading == 0 ? (fontSize * 1.2).rounded(.toNearestOrAwayFromZero) : Float(style.leading))
        tracking = try Self.finite((Float(style.tracking) * fontSize * 0.001).rounded(.toNearestOrAwayFromZero))
        if isBox {
            let boxX = try Self.finite(Float(source.boxPosition.x))
            let boxY = try Self.finite(Float(source.boxPosition.y))
            let boxWidth = try Self.finite(Float(source.boxSize.x))
            let boxHeight = try Self.finite(Float(source.boxSize.y))
            guard boxWidth > 0, boxHeight > 0 else { throw PAGError.unsupportedFeature("textBoxDimensions") }
            guard lineGap > 0 else { throw PAGError.unsupportedFeature("textBoxLeading") }
            // 竖框先交换轴复用横排算法，最终位置再映回原框右边缘；不在此改 glyph 轮廓。
            width = isVertical ? boxHeight : boxWidth
            height = isVertical ? boxWidth : boxHeight
            originX = try Self.finite(isVertical ? boxX + boxWidth : boxX)
            originY = boxY
            let sourceBaseline = try Self.finite(Float(source.firstBaseline))
            firstBaseline = try Self.finite(isVertical ? originX - sourceBaseline : sourceBaseline - boxY)
        } else {
            width = .infinity
            height = .infinity
            originX = 0
            originY = 0
            firstBaseline = 0
        }
        var minAscent: Float = 0
        var maxDescent: Float = 0
        for glyph in glyphs {
            try work.consume()
            guard glyph.advance.isFinite, glyph.ascent.isFinite, glyph.descent.isFinite else {
                throw SceneValidator.invalid("unrepresentableTextLayout")
            }
            try glyph.bounds.validate()
            minAscent = min(minAscent, glyph.ascent)
            maxDescent = max(maxDescent, glyph.descent)
        }
        let metricHeight = try Self.finite(maxDescent - minAscent)
        guard metricHeight > 0 else { throw SceneValidator.invalid("missingTextMetrics") }
        let lineHeight = try Self.finite(fontSize * 1.2)
        // 这里按字体指标比例拆分默认行高，不直接把字体 ascent/descent 当作 PAG 行高。
        fontBottom = try Self.finite((maxDescent / metricHeight) * lineHeight)
        fontTop = try Self.finite(fontBottom - lineHeight)
    }

    /// 将最终基线位置映射到图层；使用精确90度系数，避免重复旋转字形自身轮廓。
    func position(x: Float, y: Float) throws -> ScenePoint {
        let mappedX = try Self.finite((isVertical ? -y : x) + originX)
        let mappedY = try Self.finite((isVertical ? x : y) + originY)
        return ScenePoint(x: Double(mappedX), y: Double(mappedY))
    }

    /// 映射整体逻辑边界；竖排的轴交换/反向必须与位置映射完全一致。
    func map(_ bounds: TextLayoutBounds) throws -> TextLayoutBounds {
        let result: TextLayoutBounds
        if isVertical {
            result = TextLayoutBounds(left: originX - bounds.bottom, top: originY + bounds.left,
                                      right: originX - bounds.top, bottom: originY + bounds.right)
        } else {
            result = TextLayoutBounds(left: originX + bounds.left, top: originY + bounds.top,
                                      right: originX + bounds.right, bottom: originY + bounds.bottom)
        }
        try result.validate()
        return result
    }

    /// 在 Float 计算产生无穷或 NaN 时拒绝结果，不把异常坐标送往后续资源准备。
    static func finite(_ value: Float) throws -> Float {
        guard value.isFinite else { throw SceneValidator.invalid("unrepresentableTextLayout") }
        return value
    }
}
