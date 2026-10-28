/// 跑马灯优先原字号单行排版，轮廓超高时等比适配；只有宽度仍超框才滚动。
enum MarqueeTextPreparation {
    /// 返回实际文本资源与超框宽度；nil宽度表示放得下，不应额外滚动。
    static func prepare(_ source: SourceText, reference: SourceLayerReference,
                        style: PAGText, budget: inout FramePlanBudget)
        throws -> (text: PreparedTextLayer, scrollingWidth: Double?) {
        guard source.isBoxText, source.direction != 2,
              source.boxSize.x > 0, source.boxSize.y > 0 else {
            throw PAGError.unsupportedFeature("textOverflowLayout")
        }
        guard !style.text.contains(where: { $0.isNewline }) else {
            throw PAGError.unsupportedFeature("marqueeMultiline")
        }
        // 点文本不执行框内自动缩字号；左对齐基线之后在帧计划中回到原文本框位置。
        let unbounded = pointSource(source)
        let raw = try TextPreparation.prepare(unbounded, reference: reference,
            style: style, budget: &budget)
        let candidate = try TextInkFitting.fit(raw, in: source, pointBaseline: source.firstBaseline, budget: &budget)
        let width = Double(candidate.layout.lines.first?.advance ?? 0)
        guard width.isFinite, width >= 0 else {
            throw PAGError.unsupportedFeature("marqueeTextWidth")
        }
        if width > source.boxSize.x {
            return (candidate, width)
        }
        return (try TextInkFitting.placePointText(candidate, in: source, budget: &budget), nil)
    }

    /// 溢出时供静态排版和动态字距共用的左对齐点文本参数，避免两阶段采用不同对齐原点。
    static func pointSource(_ source: SourceText) -> SourceText {
        SourceText(style: source.style, baselineShift: source.baselineShift,
            firstBaseline: source.firstBaseline, isBoxText: false,
            boxPosition: source.boxPosition, boxSize: source.boxSize,
            fauxBold: source.fauxBold, fauxItalic: source.fauxItalic,
            strokeOverFill: source.strokeOverFill, justification: 0,
            backgroundColor: source.backgroundColor, backgroundAlpha: source.backgroundAlpha,
            direction: source.direction)
    }
}
