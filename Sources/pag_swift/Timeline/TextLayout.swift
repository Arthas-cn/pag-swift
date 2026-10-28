/// 已整形 glyph 的 PAG 纯值排版器；由后台准备调用，不接触 CoreText、UI 或 Metal。
enum TextLayout {
    /// 为非动画 SourceText 和当前编辑样式排版；预算、取消或不可表示语义失败时不返回部分结果。
    static func layout(_ glyphs: [TextGlyphMetrics], source: SourceText, style: PAGText,
                       budget: inout FramePlanBudget, maximumWork: Int = 4_194_304) throws -> TextLayoutResult {
        try Task.checkCancellation()
        try style.validate()
        guard maximumWork > 0 else { throw PAGError.invalidArgument("maximumTextLayoutWork") }
        // 一次为最坏的“每 glyph 一行”输出计费，再分配数组；不在候选字号循环中复制输入。
        try budget.reserve(count: glyphs.count, stride: 256)
        guard !glyphs.isEmpty else {
            return TextLayoutResult(glyphs: [], lines: [], glyphScale: 1, bounds: nil)
        }
        var work = TextLayoutWork(maximum: maximumWork)
        var settings = try TextLayoutSettings(source: source, style: style, glyphs: glyphs, work: &work)
        if settings.isBox { try settings.fit(glyphs, work: &work) }
        return try place(glyphs, settings: settings, work: &work)
    }

    /// 根据最终字号逐行输出位置和逻辑 bounds；换行与框底停止规则均沿源 TextRenderer。
    private static func place(_ glyphs: [TextGlyphMetrics], settings: TextLayoutSettings,
                              work: inout TextLayoutWork) throws -> TextLayoutResult {
        var placements: [TextGlyphPlacement] = []
        placements.reserveCapacity(glyphs.count)
        var lines: [TextLayoutLine] = []
        var bounds: TextLayoutBounds?
        var index = 0
        var baseline = settings.firstBaseline
        while index < glyphs.count {
            try work.consume()
            // 源规则检查 baseline 而非 glyph.bottom；这里没有额外的文字框裁剪。
            if baseline > settings.height { break }
            let start = index
            let line = try TextLineBreaking.next(glyphs, from: start, scale: settings.glyphScale,
                                                 width: settings.width, tracking: settings.tracking, work: &work)
            let hasBreak = glyphs[line.end - 1].isLineBreak
            let end = line.end - (hasBreak ? 1 : 0)
            index = line.end
            // 显式换行结束一个段落，因此 FullJustify 使用末行策略；自动折行则继续拉伸。
            let lastLine = index == glyphs.count || hasBreak
            let boxWidth = settings.isBox ? settings.width : nil
            var drawX = try TextLayoutSettings.finite(TextLineBreaking.startX(justification: settings.justification,
                                                                             width: line.width, lastLine: lastLine,
                                                                             boxWidth: boxWidth))
            let drawY = try TextLayoutSettings.finite(baseline - settings.baselineShift)
            let spacing = try TextLineBreaking.spacing(justification: settings.justification, tracking: settings.tracking,
                                                       width: line.width, count: end - start, lastLine: lastLine, boxWidth: boxWidth)
            let outputStart = placements.count
            for glyphIndex in start..<end {
                try work.consume()
                let glyph = glyphs[glyphIndex]
                let position = try settings.position(x: drawX, y: drawY)
                placements.append(TextGlyphPlacement(glyphIndex: glyphIndex, position: position))
                let glyphBounds = try glyph.bounds.placed(scale: settings.glyphScale, x: drawX, y: drawY)
                if glyphBounds.hasArea { bounds = bounds.map { $0.union(glyphBounds) } ?? glyphBounds }
                drawX = try TextLayoutSettings.finite(drawX + (glyph.advance * settings.glyphScale + spacing))
            }
            if outputStart == placements.count {
                let emptyBounds = TextLayoutBounds(left: drawX, top: drawY + settings.fontTop,
                                                   right: drawX + 1, bottom: drawY + settings.fontBottom)
                try emptyBounds.validate()
                if emptyBounds.hasArea { bounds = bounds.map { $0.union(emptyBounds) } ?? emptyBounds }
            }
            lines.append(TextLayoutLine(glyphRange: outputStart..<placements.count, advance: line.width, baseline: drawY))
            baseline = try TextLayoutSettings.finite(baseline + settings.lineGap)
        }
        try Task.checkCancellation()
        return try TextLayoutResult(glyphs: placements, lines: lines, glyphScale: settings.glyphScale,
                                    bounds: bounds.map { try settings.map($0) })
    }
}
