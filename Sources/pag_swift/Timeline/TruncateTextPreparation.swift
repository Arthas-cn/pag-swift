import Foundation

/// 动态文本的单行尾部截断；只在场景准备时测宽，不进入逐帧 Metal 热路径。
enum TruncateTextPreparation {
    /// 用 PAG 已有的 CoreText 字形准备测量前缀；非法框或多行请求明确失败。
    static func prepare(_ source: SourceText, reference: SourceLayerReference,
                        style: PAGText, budget: inout FramePlanBudget) throws -> PreparedTextLayer {
        guard source.isBoxText, source.direction == 0,
              source.boxSize.x > 0, source.boxSize.y > 0,
              !style.text.contains(where: { $0.isNewline }) else {
            throw PAGError.unsupportedFeature("truncateTextLayout")
        }
        let point = MarqueeTextPreparation.pointSource(source)
        let full = try TextPreparation.prepare(point, reference: reference, style: style, budget: &budget)
        if width(of: full) <= source.boxSize.x {
            let fitted = try TextPreparation.prepare(source, reference: reference, style: style, budget: &budget)
            return try TextInkFitting.fit(fitted, in: source, budget: &budget)
        }
        let characters = Array(style.text)
        var lower = 0
        var upper = characters.count
        var best = "…"
        while lower <= upper {
            try Task.checkCancellation()
            let middle = lower + (upper - lower) / 2
            var trial = style
            trial.text = String(characters.prefix(middle)) + "…"
            let measured = try TextPreparation.prepare(point, reference: reference, style: trial, budget: &budget)
            if width(of: measured) <= source.boxSize.x {
                best = trial.text
                lower = middle + 1
            } else {
                if middle == 0 { break }
                upper = middle - 1
            }
        }
        var result = style
        result.text = best
        // 省略号比框还宽时仍只保留省略号；随后按实际轮廓适配，不能恢复整串超宽文字。
        let fitted = try TextPreparation.prepare(source, reference: reference, style: result, budget: &budget)
        return try TextInkFitting.fit(fitted, in: source, budget: &budget)
    }

    /// 读取同一字形布局的真实单行 advance；空串宽度为零。
    private static func width(of text: PreparedTextLayer) -> Double {
        Double(text.layout.lines.first?.advance ?? 0)
    }
}
