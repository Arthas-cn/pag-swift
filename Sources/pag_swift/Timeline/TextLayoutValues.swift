/// 整形层交给纯排版器的单个 glyph 指标；不持有字体，也不把 Swift Character 当作 glyph。
struct TextGlyphMetrics: Sendable {
    /// 在当前文字方向上的 nominal advance；负值按源指标保留。
    let advance: Float
    /// 当前方向的字体上边界，通常为负；排版取所有 glyph 与零的最小值。
    let ascent: Float
    /// 当前方向的字体下边界，通常为正；排版取所有 glyph 与零的最大值。
    let descent: Float
    /// 已转换到统一横排计算空间的逻辑边界；竖排 extraMatrix 由整形层先处理。
    let bounds: TextLayoutBounds
    /// 对应源 cluster 是否以换行符开头；该项占输入索引但不生成绘制位置。
    let isLineBreak: Bool
}

/// 排版计算空间中的有限 Float 边界，允许零面积；不等同于实际字形覆盖像素。
struct TextLayoutBounds: Sendable, Equatable {
    /// 最左坐标，不大于 right。
    let left: Float
    /// 最上坐标，不大于 bottom。
    let top: Float
    /// 最右坐标，允许等于 left。
    let right: Float
    /// 最下坐标，允许等于 top。
    let bottom: Float

    /// 是否覆盖非零逻辑面积；空字形不能扩大普通 glyph 的并集。
    var hasArea: Bool { left < right && top < bottom }

    /// 校验整形输入及运算输出；非有限或倒置边界拒绝进入共享结果。
    func validate() throws {
        guard left.isFinite, top.isFinite, right.isFinite, bottom.isFinite,
              left <= right, top <= bottom else { throw SceneValidator.invalid("unrepresentableTextLayout") }
    }

    /// 应用正字形缩放与排版平移，保持上游先缩放后偏移的 Float 运算次序。
    func placed(scale: Float, x: Float, y: Float) throws -> TextLayoutBounds {
        let result = TextLayoutBounds(left: left * scale + x, top: top * scale + y,
                                      right: right * scale + x, bottom: bottom * scale + y)
        try result.validate()
        return result
    }

    /// 合并两个已有面积的逻辑范围；调用者在加入空范围前先检查 hasArea。
    func union(_ other: TextLayoutBounds) -> TextLayoutBounds {
        TextLayoutBounds(left: min(left, other.left), top: min(top, other.top),
                         right: max(right, other.right), bottom: max(bottom, other.bottom))
    }
}

/// 排版后单个 glyph 的图层局部基线位置；字形自身竖排变换及缩放另行应用。
struct TextGlyphPlacement: Sendable {
    /// 对应整形输入数组的原索引，换行符留下的间隔不重编号。
    let glyphIndex: Int
    /// 已应用框原点、方向和 baselineShift 的位置，不包含图层时间轴变换。
    let position: ScenePoint
}

/// 一个逻辑行的结果；空行仍保留，供诊断和整体 bounds 验证。
struct TextLayoutLine: Sendable {
    /// 本行在 TextLayoutResult.glyphs 中的范围，空行范围为空。
    let glyphRange: Range<Int>
    /// 断行时的总 advance，含原 tracking，不含 FullJustify 后补充的间距。
    let advance: Float
    /// 统一横排计算空间中的基线，已减 baselineShift，尚未映射文字方向。
    let baseline: Float
}

/// 不可变排版结果；只能证明 glyph 位置，不能代替字体、字形资源或 FramePlan。
struct TextLayoutResult: Sendable {
    /// 按实际行顺序保存的可布局 glyph，未包含换行符及框底以后的输入。
    let glyphs: [TextGlyphPlacement]
    /// 包含显式空行的逻辑行列表；源末尾换行不会凭空新增一行。
    let lines: [TextLayoutLine]
    /// 自动适应文字框的统一正缩放；点文本为1。
    let glyphScale: Float
    /// 图层局部坐标中的总逻辑边界；没有非零范围时为 nil。
    let bounds: TextLayoutBounds?
}

/// 限制候选字号和 glyph 遍历的总工作量；与内存预算独立，避免无界重排。
struct TextLayoutWork {
    /// 当前调用还可执行的正数或零次逻辑操作，失败后不发布结果。
    private var remaining: Int

    /// 保存已校验为正的调用上限。
    init(maximum: Int) { remaining = maximum }

    /// 每次候选/输入/输出操作扣减并响应取消；不以近似布局代替超限失败。
    mutating func consume() throws {
        try Task.checkCancellation()
        guard remaining > 0 else { throw PAGError.resourceLimitExceeded("maximumTextLayoutWork") }
        remaining -= 1
    }
}
