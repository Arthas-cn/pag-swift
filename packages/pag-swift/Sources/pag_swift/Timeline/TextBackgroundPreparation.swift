import Foundation

/// 文字背景使用的Float矩形，先保留上游相邻行修正和取整顺序。
private struct TextBackgroundRect {
    /// 图层局部左边界，允许为负。
    var left: Float
    /// 图层局部上边界，允许为负。
    var top: Float
    /// 图层局部右边界，始终不小于left。
    var right: Float
    /// 图层局部下边界，始终不小于top。
    var bottom: Float

    /// 当前矩形有非零面积；空行不加入背景路径。
    var hasArea: Bool { left < right && top < bottom }

    /// 合并同一行所有字形条形的轴对齐边界。
    mutating func include(_ other: TextBackgroundRect) {
        left = min(left, other.left)
        top = min(top, other.top)
        right = max(right, other.right)
        bottom = max(bottom, other.bottom)
    }
}

/// 从已排版且已应用动画器的全部glyph指标生成背景圆角矩形轮廓。
enum TextBackgroundPreparation {
    /// 按TextRenderer::RenderBackgroundPath的行间距修正输出一个可直接画Metal的复合几何。
    static func prepare(text: PreparedTextLayer, source: SourceText,
                        budget: inout FramePlanBudget) throws -> ShapeGeometry? {
        try Task.checkCancellation()
        guard source.backgroundAlpha > 0, !text.backgroundGlyphs.isEmpty else { return nil }
        guard text.backgroundGlyphs.count == text.layout.glyphs.count else {
            throw SceneValidator.invalid("textBackgroundLayoutIdentity")
        }
        try budget.reserve(count: text.backgroundGlyphs.count, stride: 160)
        try budget.reserve(count: text.layout.lines.count, stride: 256)
        let vertical = source.direction == 2
        var lineTop: Float = 0
        var lineBottom: Float = 0
        for glyph in text.backgroundGlyphs {
            try Task.checkCancellation()
            if vertical {
                lineTop = min(lineTop, -glyph.bounds.right)
                lineBottom = max(lineBottom, -glyph.bounds.left)
            } else {
                lineTop = min(lineTop, glyph.bounds.top)
                lineBottom = max(lineBottom, glyph.bounds.bottom)
            }
        }
        let margin = max(Float(text.style.fontSize) * 0.4, Float(text.style.strokeWidth))
        guard lineTop.isFinite, lineBottom.isFinite, margin.isFinite else {
            throw SceneValidator.invalid("unrepresentableTextBackground")
        }
        var lines: [TextBackgroundRect] = []
        for line in text.layout.lines {
            try Task.checkCancellation()
            var combined: TextBackgroundRect?
            for index in line.glyphRange {
                let glyph = text.backgroundGlyphs[index]
                let rect = try mapped(glyph, top: lineTop, bottom: lineBottom, vertical: vertical)
                if let current = combined { var next = current; next.include(rect); combined = next }
                else { combined = rect }
            }
            guard var rect = combined, rect.hasArea else { continue }
            rect.left -= margin
            rect.top -= margin
            rect.right += margin
            rect.bottom += margin
            guard [rect.left, rect.top, rect.right, rect.bottom].allSatisfy(\.isFinite) else {
                throw SceneValidator.invalid("unrepresentableTextBackground")
            }
            lines.append(rect)
        }
        guard !lines.isEmpty else { return nil }
        var topInset: Float = 0
        var bottomInset: Float = 0
        var leftInset: Float = 0
        var rightInset: Float = 0
        for index in lines.indices {
            try Task.checkCancellation()
            var rect = lines[index]
            if index + 1 < lines.count {
                let next = lines[index + 1]
                if vertical { leftInset = max((rect.left - next.right) * 0.5, 0) }
                else { bottomInset = max((next.top - rect.bottom) * 0.5, 0) }
            }
            rect.left = (rect.left - leftInset).rounded(.toNearestOrAwayFromZero)
            rect.right = (rect.right + rightInset).rounded(.toNearestOrAwayFromZero)
            rect.top = (rect.top - topInset).rounded(.toNearestOrAwayFromZero)
            rect.bottom = (rect.bottom + bottomInset).rounded(.toNearestOrAwayFromZero)
            guard [rect.left, rect.top, rect.right, rect.bottom].allSatisfy(\.isFinite) else {
                throw SceneValidator.invalid("unrepresentableTextBackground")
            }
            lines[index] = rect
            topInset = bottomInset
            rightInset = leftInset
        }
        let overall = lines.dropFirst().reduce(lines[0]) { previous, item in
            var result = previous
            result.include(item)
            return result
        }
        let radius = min(min(overall.right - overall.left, overall.bottom - overall.top) / 3, 25)
        guard radius.isFinite else { throw SceneValidator.invalid("unrepresentableTextBackground") }
        try budget.reserve(count: lines.count, stride: 192)
        var contours: [ShapeContour] = []
        for rect in lines where rect.hasArea {
            try Task.checkCancellation()
            // Corner效果对每条闭合矩形轮廓应用统一半径，窄行由单轮廓自身再钳位。
            let localRadius = max(min(radius, (rect.right - rect.left) * 0.5,
                                      (rect.bottom - rect.top) * 0.5), 0)
            contours.append(.rectangle(RoundedRectangleContour(left: Double(rect.left), top: Double(rect.top),
                right: Double(rect.right), bottom: Double(rect.bottom), radius: Double(localRadius),
                reversed: false, matrix: .identity)))
        }
        guard !contours.isEmpty else { return nil }
        return try ShapeGeometry(contours: contours)
    }

    /// 将单个glyph的背景条形经其当帧总矩阵映射，再取轴对齐外接矩形。
    private static func mapped(_ glyph: TextBackgroundGlyph, top: Float, bottom: Float,
                               vertical: Bool) throws -> TextBackgroundRect {
        let x0 = vertical ? -bottom : 0
        let y0 = vertical ? 0 : top
        let x1 = vertical ? -top : Float(glyph.advance)
        let y1 = vertical ? Float(glyph.advance) : bottom
        var xMin = Float.infinity
        var yMin = Float.infinity
        var xMax = -Float.infinity
        var yMax = -Float.infinity
        for point in [ScenePoint(x: Double(x0), y: Double(y0)), ScenePoint(x: Double(x1), y: Double(y0)),
                      ScenePoint(x: Double(x1), y: Double(y1)), ScenePoint(x: Double(x0), y: Double(y1))] {
            let result = try glyph.matrix.applying(to: point)
            let x = Float(result.x), y = Float(result.y)
            guard x.isFinite, y.isFinite else { throw SceneValidator.invalid("unrepresentableTextBackground") }
            xMin = min(xMin, x)
            yMin = min(yMin, y)
            xMax = max(xMax, x)
            yMax = max(yMax, y)
        }
        return TextBackgroundRect(left: xMin, top: yMin, right: xMax, bottom: yMax)
    }
}
