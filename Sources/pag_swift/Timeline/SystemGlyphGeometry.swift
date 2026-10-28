import CoreText
import CoreGraphics

/// 单次文字准备中的可共享字形几何和字体指标；系统对象已转换为 Sendable 值。
struct SystemGlyphGeometry: Sendable {
    /// 未排版的普通或伪粗斜体填充轮廓。
    let fill: GlyphOutline
    /// 已准备的有效描边轮廓；没有描边时为 nil。
    let stroke: GlyphOutline?
    /// 固定 CG 后端的水平逻辑边界，含取整和抗锯齿预留。
    let bounds: TextLayoutBounds
    /// 普通空格的 A 字形上下边界；A 不存在时沿用原 bounds。
    let spaceBounds: TextLayoutBounds
    /// 横排 nominal advance，不含字距或系统 kerning。
    let advance: Float
    /// 竖排 nominal advance，零时由使用方退回横排值。
    let verticalAdvance: Float
    /// CoreText 竖排原点偏移，y 已翻成 PAG 方向。
    let verticalOffset: ScenePoint
    /// 字体 ascent，PAG 向下坐标下通常为负。
    let ascent: Float
    /// 字体 descent，通常为正。
    let descent: Float
    /// 竖排 ASCII 左移量，由 capHeight 与 xHeight 决定。
    let asciiOffset: Float

    /// 根据 cluster 与方向生成 Glyph.cpp 对应的布局指标及自身变换，不重复缩字号或平移基线。
    func placementMetrics(cluster: TextCluster, vertical: Bool) throws -> (TextGlyphMetrics, SceneAffine) {
        var box = cluster.isSpace ? spaceBounds : bounds
        var glyphAdvance = advance
        var glyphAscent = ascent
        var glyphDescent = descent
        var matrix = SceneAffine.identity
        if vertical {
            if cluster.isSingleByte {
                matrix = try SceneAffine(a: 0, b: 1, c: -1, d: 0, tx: -Double(asciiOffset), ty: 0)
                glyphAscent += asciiOffset
                glyphDescent += asciiOffset
                // 自身先转90度，GlyphInfo 再转−90度；统一横排 bounds 只剩字体居中偏移。
                box = try box.placed(scale: 1, x: 0, y: asciiOffset)
            } else {
                matrix = try .translation(x: verticalOffset.x, y: verticalOffset.y)
                glyphAdvance = verticalAdvance == 0 ? advance : verticalAdvance
                glyphAscent = -advance * 0.5
                glyphDescent = advance * 0.5
                let x = Float(verticalOffset.x)
                let y = Float(verticalOffset.y)
                box = TextLayoutBounds(left: box.top + y, top: -(box.right + x), right: box.bottom + y, bottom: -(box.left + x))
                try box.validate()
            }
        }
        return (TextGlyphMetrics(advance: glyphAdvance, ascent: glyphAscent, descent: glyphDescent,
                                 bounds: box, isLineBreak: cluster.isLineBreak), matrix)
    }

    /// 从同一次后台作用域中的字体建立完整路径与指标；返回前再次检查取消。
    static func prepare(font: CTFont, id: CGGlyph, source: SourceText, style: PAGText,
                        budget: inout FramePlanBudget) throws -> SystemGlyphGeometry {
        try Task.checkCancellation()
        try budget.reserve(stride: 512)
        let size = Float(style.fontSize)
        let boldWidth = source.fauxBold ? size * fauxBoldScale(size) : 0
        let ascent = try TextLayoutSettings.finite(-Float(CTFontGetAscent(font)))
        let descent = try TextLayoutSettings.finite(Float(CTFontGetDescent(font)))
        let asciiOffset = try TextLayoutSettings.finite((Float(CTFontGetCapHeight(font)) + Float(CTFontGetXHeight(font))) * 0.25)
        var glyph = id
        var cgAdvance = CGSize.zero
        var cgVertical = CGSize.zero
        var cgOffset = CGSize.zero
        if id != 0 {
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &cgAdvance, 1)
            CTFontGetAdvancesForGlyphs(font, .vertical, &glyph, &cgVertical, 1)
            CTFontGetVerticalTranslationsForGlyphs(font, &glyph, &cgOffset, 1)
        }
        let advance = try TextLayoutSettings.finite(Float(cgAdvance.width))
        let verticalAdvance = try TextLayoutSettings.finite(Float(cgVertical.width))
        let offset = ScenePoint(x: Double(try TextLayoutSettings.finite(Float(cgOffset.width))),
                                y: Double(try TextLayoutSettings.finite(-Float(cgOffset.height))))
        var bounds = try glyphBounds(font: font, id: id, italic: source.fauxItalic, boldWidth: boldWidth)
        if !bounds.hasArea && advance > 0 {
            bounds = TextLayoutBounds(left: 0, top: ascent, right: advance, bottom: descent)
            try bounds.validate()
        }
        var spaceBounds = bounds
        var a: UniChar = 65
        var aGlyph: CGGlyph = 0
        if CTFontGetGlyphsForCharacters(font, &a, &aGlyph, 1), aGlyph != 0 {
            let aBounds = try glyphBounds(font: font, id: aGlyph, italic: source.fauxItalic, boldWidth: boldWidth)
            spaceBounds = TextLayoutBounds(left: bounds.left, top: aBounds.top, right: bounds.right, bottom: aBounds.bottom)
        }
        // 固定 CG 后端在 y 向上时使用 +0.20；路径提取再翻 y，得到 PAG 的−0.20 skew。
        var italic = CGAffineTransform(a: 1, b: 0, c: source.fauxItalic ? CGFloat(Float(0.20)) : 0, d: 1, tx: 0, ty: 0)
        var path = id == 0 ? nil : CTFontCreatePathForGlyph(font, id, &italic)
        if boldWidth > 0, let original = path {
            let stroke = original.copy(strokingWithWidth: CGFloat(boldWidth), lineCap: .butt, lineJoin: .miter, miterLimit: 4)
            path = original.union(stroke, using: .winding)
        }
        let fill = try GlyphOutline.copy(path, budget: &budget)
        var stroke: GlyphOutline?
        if style.strokeColor != nil, Float(style.strokeWidth) >= 0.1 {
            let width = try TextLayoutSettings.finite(Float(style.strokeWidth))
            let stroked = path?.copy(strokingWithWidth: CGFloat(width), lineCap: .butt, lineJoin: .miter, miterLimit: 4)
            stroke = try GlyphOutline.copy(stroked, budget: &budget)
        }
        try Task.checkCancellation()
        return SystemGlyphGeometry(fill: fill, stroke: stroke, bounds: bounds, spaceBounds: spaceBounds, advance: advance,
                                   verticalAdvance: verticalAdvance, verticalOffset: offset,
                                   ascent: ascent, descent: descent, asciiOffset: asciiOffset)
    }

    /// 固定 FauxBoldScale 的两端钳制及线性过渡，不把伪粗体替换成另一款 Bold 字体。
    private static func fauxBoldScale(_ size: Float) -> Float {
        if size <= 9 { return 1 / 24 }
        if size >= 36 { return 1 / 32 }
        return Float(1) / 24 + (Float(1) / 32 - Float(1) / 24) * ((size - 9) / 27)
    }

    /// 按 CGScalerContext 的 Float 转换、伪粗体边界、roundOut 与扩1规则计算逻辑 bounds。
    private static func glyphBounds(font: CTFont, id: CGGlyph, italic: Bool, boldWidth: Float) throws -> TextLayoutBounds {
        let empty = TextLayoutBounds(left: 0, top: 0, right: 0, bottom: 0)
        guard id != 0 else { return empty }
        var glyph = id
        let raw = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
        let rect = raw.applying(CGAffineTransform(a: 1, b: 0, c: italic ? CGFloat(Float(0.20)) : 0, d: 1, tx: 0, ty: 0))
        guard !rect.isEmpty else { return empty }
        let x = try TextLayoutSettings.finite(Float(rect.origin.x))
        let y = try TextLayoutSettings.finite(Float(-rect.origin.y - rect.height))
        let result = TextLayoutBounds(left: (x - boldWidth).rounded(.down) - 1,
                                      top: (y - boldWidth).rounded(.down) - 1,
                                      right: (x + Float(rect.width) + boldWidth).rounded(.up) + 1,
                                      bottom: (y + Float(rect.height) + boldWidth).rounded(.up) + 1)
        try result.validate()
        return result
    }
}
