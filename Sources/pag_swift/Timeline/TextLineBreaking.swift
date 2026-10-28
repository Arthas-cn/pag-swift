/// 一次按 advance 扫描的结果；end 指向下一项，width 不包括末尾换行符。
struct TextLineBreak {
    /// 当前行消费后的右开输入下标，至少比起点大1。
    let end: Int
    /// 缩放后 advance 与原 tracking 的累积宽度。
    let width: Float
}

/// 源 TextRenderer 的断行和对齐规则；不做系统按词断行或 Unicode 整形。
enum TextLineBreaking {
    /// 从合法非末尾下标扫描一行，至少消费一项；显式换行被消费但不贡献宽度。
    static func next(_ glyphs: [TextGlyphMetrics], from start: Int, scale: Float, width maximum: Float,
                     tracking: Float, work: inout TextLayoutWork) throws -> TextLineBreak {
        var index = start
        var width: Float = 0
        var hasPrevious = false
        while index < glyphs.count {
            try work.consume()
            let glyph = glyphs[index]
            index += 1
            if glyph.isLineBreak { break }
            width = try TextLayoutSettings.finite(width + glyph.advance * scale)
            if hasPrevious { width = try TextLayoutSettings.finite(width + tracking) }
            hasPrevious = true
            // 源码先消费当前项再探测下一项；超宽首 glyph 仍属于这一行，不能形成空转。
            let nextWidth = index < glyphs.count ? glyphs[index].advance * scale : 0
            let proposed = try TextLayoutSettings.finite(width + tracking + nextWidth)
            if proposed > maximum { break }
        }
        return TextLineBreak(end: index, width: width)
    }

    /// 计算行首偏移；点文本的 FullJustify 沿源码视作左对齐，不假设存在无限宽框。
    static func startX(justification: UInt8, width: Float, lastLine: Bool, boxWidth: Float?) -> Float {
        guard let boxWidth else {
            switch justification {
            case 1: return -width * 0.5
            case 2: return -width
            default: return 0
            }
        }
        switch justification {
        case 1: return boxWidth * 0.5 - width * 0.5
        case 2: return boxWidth - width
        case 4 where lastLine: return boxWidth - width
        case 5 where lastLine: return boxWidth * 0.5 - width * 0.5
        default: return 0
        }
    }

    /// FullJustify 只在实际存在相邻 glyph 时分摊宽度；空行/单项避免上游的零分母中间值。
    static func spacing(justification: UInt8, tracking: Float, width: Float, count: Int,
                        lastLine: Bool, boxWidth: Float?) throws -> Float {
        guard let boxWidth, count > 1,
              justification == 6 || (justification >= 3 && !lastLine) else { return tracking }
        let intervals = Float(count - 1)
        return try TextLayoutSettings.finite((boxWidth - width + intervals * tracking) / intervals)
    }
}

/// 文字框适应独立于位置输出，避免在每轮候选字号建立整份 glyph 数组。
extension TextLayoutSettings {
    /// 按源字号逐次减1寻找可容纳的布局；保留源码末次计数与小字号边界，超限/取消明确失败。
    mutating func fit(_ glyphs: [TextGlyphMetrics], work: inout TextLayoutWork) throws {
        let boxLines = try Self.finite(((height - firstBaseline) / lineGap).rounded(.down) + 1)
        let visibleTop = try Self.finite(firstBaseline + fontTop)
        let visibleBottom = try Self.finite(firstBaseline + lineGap * (boxLines - 1) + fontBottom)
        var candidateSize = fontSize
        var totalLines: Float = 0
        // 源算法在字号不大于5时结束；最后一次失败计数仍参与后续基线调整。
        while candidateSize > 5 {
            try work.consume()
            totalLines = 0
            let scale = candidateSize / fontSize
            var baseline = try Self.finite(visibleTop - fontTop * scale)
            let currentTracking = try Self.finite(tracking * scale)
            let currentLineGap = try Self.finite(lineGap * scale)
            var index = 0
            var fits = true
            while index < glyphs.count {
                index = try TextLineBreaking.next(glyphs, from: index, scale: scale, width: width,
                                                  tracking: currentTracking, work: &work).end
                if try Self.finite(baseline + fontBottom * scale) > visibleBottom || baseline > height {
                    fits = false
                    break
                }
                baseline = try Self.finite(baseline + currentLineGap)
                totalLines += 1
            }
            if fits { break }
            let next = candidateSize - 1
            // 极大 Float 字号减1可能不再变化，继续循环既无法重现有效布局也无法终止。
            guard next < candidateSize else { throw PAGError.resourceLimitExceeded("maximumTextLayoutWork") }
            candidateSize = next
        }
        let scale = candidateSize / fontSize
        if scale != 1 {
            // 缩字时固定可见区域上沿，再对单行补半个行距差；baselineShift 保持源单位。
            glyphScale = scale
            firstBaseline = try Self.finite(visibleTop + -fontTop * scale)
            if totalLines == 1 { firstBaseline = try Self.finite(firstBaseline + (1 - scale) * 0.5 * lineGap) }
            fontTop = try Self.finite(fontTop * scale)
            fontBottom = try Self.finite(fontBottom * scale)
            tracking = try Self.finite(tracking * scale)
            lineGap = try Self.finite(lineGap * scale)
        } else if totalLines < boxLines {
            // 不缩字且行数不足时仍须纵向居中，不能简单保留文件的首基线。
            firstBaseline = try Self.finite(firstBaseline + (boxLines - totalLines) * lineGap * 0.5)
        }
    }
}
