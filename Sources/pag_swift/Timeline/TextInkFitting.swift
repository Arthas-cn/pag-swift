import CoreGraphics

/// 动态文字安装时按实际填充/描边轮廓适配槽位；不改变源 PAG 排版或逐帧生成路径。
enum TextInkFitting {
    /// 保持已有断行和对齐，仅在越界时平移或等比缩小；滚动文字只约束高度。
    /// pointBaseline 非 nil 表示点文本随后会被放回源框基线，返回值仍使用点文本坐标。
    static func fit(_ text: PreparedTextLayer, in source: SourceText,
                    pointBaseline: Double? = nil, budget: inout FramePlanBudget) throws -> PreparedTextLayer {
        guard source.isBoxText, source.direction != 2,
              source.boxSize.x > 0, source.boxSize.y > 0,
              let ink = try bounds(of: text, budget: &budget), !ink.isEmpty else { return text }
        let scrolling = pointBaseline != nil
        let left = scrolling ? 0 : source.boxPosition.x
        let top = source.boxPosition.y - (pointBaseline ?? 0)
        // 半个合成点留给抗锯齿；极小框按比例留白，不能产生负的可用尺寸。
        let inset = min(0.5, min(source.boxSize.x, source.boxSize.y) * 0.05)
        let height = source.boxSize.y - 2 * inset
        let width = source.boxSize.x - 2 * inset
        let scale = min(1, height / ink.height, scrolling ? 1 : width / ink.width)
        let x = scrolling ? 0 : correction(minimum: ink.minX * scale, maximum: ink.maxX * scale,
                                          lower: left + inset, upper: left + source.boxSize.x - inset)
        let y = correction(minimum: ink.minY * scale, maximum: ink.maxY * scale,
                           lower: top + inset, upper: top + source.boxSize.y - inset)
        guard scale != 1 || x != 0 || y != 0 else { return text }
        return try transformed(text, scale: scale, x: x, y: y, budget: &budget)
    }

    /// 不滚动的点文本按原框水平对齐并放回基线；不能重新走框排版，否则超高缩字后可能意外换行。
    static func placePointText(_ text: PreparedTextLayer, in source: SourceText,
                               budget: inout FramePlanBudget) throws -> PreparedTextLayer {
        let width = text.layout.lines.first?.advance ?? 0
        let x = TextLineBreaking.startX(justification: source.justification, width: width,
                                       lastLine: true, boxWidth: Float(source.boxSize.x))
        let placed = try transformed(text, scale: 1, x: source.boxPosition.x + Double(x),
                                     y: source.firstBaseline, budget: &budget)
        return try fit(placed, in: source, budget: &budget)
    }

    /// 同步变换绘制轮廓、布局和背景，保持动画器及后续诊断使用的坐标一致；轮廓本身继续共享。
    private static func transformed(_ text: PreparedTextLayer, scale: Double, x: Double, y: Double,
                                    budget: inout FramePlanBudget) throws -> PreparedTextLayer {
        let adjustment = try SceneAffine.scale(x: scale, y: scale).following(.translation(x: x, y: y))
        let count = text.glyphs.count + text.layout.glyphs.count + text.layout.lines.count
            + text.backgroundGlyphs.count + text.layoutAdvances.count
        try budget.reserve(count: count, stride: 256)
        let glyphs = try text.glyphs.map { glyph in
            PreparedTextGlyph(fill: glyph.fill, stroke: glyph.stroke, matrix: try glyph.matrix.following(adjustment),
                alpha: glyph.alpha, layoutIndex: glyph.layoutIndex, advance: glyph.advance * scale,
                fontIndex: glyph.fontIndex, cluster: glyph.cluster)
        }
        let positions = try text.layout.glyphs.map {
            TextGlyphPlacement(glyphIndex: $0.glyphIndex, position: try adjustment.applying(to: $0.position))
        }
        let lines = text.layout.lines.map {
            TextLayoutLine(glyphRange: $0.glyphRange, advance: $0.advance * Float(scale),
                           baseline: $0.baseline * Float(scale) + Float(y))
        }
        let layout = TextLayoutResult(glyphs: positions, lines: lines,
            glyphScale: text.layout.glyphScale * Float(scale),
            bounds: try text.layout.bounds?.placed(scale: Float(scale), x: Float(x), y: Float(y)))
        let backgrounds = try text.backgroundGlyphs.map {
            TextBackgroundGlyph(bounds: $0.bounds, matrix: try $0.matrix.following(adjustment), advance: $0.advance * scale)
        }
        return PreparedTextLayer(source: text.source, style: text.style, glyphs: glyphs, passes: text.passes,
            layout: layout, layoutAdvances: text.layoutAdvances.map { $0 * scale }, backgroundGlyphs: backgrounds,
            fonts: text.fonts, missingGlyphIndices: text.missingGlyphIndices,
            estimatedBytes: text.estimatedBytes + count * 256)
    }

    /// 只沿越界方向移动，已在框内的原对齐、基线保持不变。
    private static func correction(minimum: Double, maximum: Double, lower: Double, upper: Double) -> Double {
        if minimum < lower { return lower - minimum }
        if maximum > upper { return upper - maximum }
        return 0
    }

    /// 计算实际启用绘制轮次的精确曲线并集；字体逻辑 bounds 不包含描边，不能用于防切字。
    static func bounds(of text: PreparedTextLayer, budget: inout FramePlanBudget) throws -> CGRect? {
        var result: CGRect?
        for glyph in text.glyphs {
            try Task.checkCancellation()
            for pass in text.passes {
                let outline: GlyphOutline?
                switch pass {
                case .fill: outline = glyph.fill
                case .stroke: outline = glyph.stroke
                }
                guard let outline, !outline.elements.isEmpty else { continue }
                try budget.reserve(count: outline.elements.count, stride: 48)
                let path = CGMutablePath()
                for element in outline.elements {
                    switch element {
                    case .move(let p): path.move(to: try point(p, matrix: glyph.matrix))
                    case .line(let p): path.addLine(to: try point(p, matrix: glyph.matrix))
                    case .quadratic(let control, let end):
                        path.addQuadCurve(to: try point(end, matrix: glyph.matrix),
                                          control: try point(control, matrix: glyph.matrix))
                    case .cubic(let first, let second, let end):
                        path.addCurve(to: try point(end, matrix: glyph.matrix),
                            control1: try point(first, matrix: glyph.matrix), control2: try point(second, matrix: glyph.matrix))
                    case .close: path.closeSubpath()
                    }
                }
                let rect = path.boundingBoxOfPath
                if !rect.isNull && !rect.isEmpty { result = result.map { $0.union(rect) } ?? rect }
            }
        }
        return result
    }

    /// 轮廓已是向下的 y 轴，只应用字形矩阵，不能再次翻转坐标。
    private static func point(_ value: ScenePoint, matrix: SceneAffine) throws -> CGPoint {
        let mapped = try matrix.applying(to: value)
        return CGPoint(x: mapped.x, y: mapped.y)
    }
}
