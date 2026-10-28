import Foundation

/// 动画后同一字体与局部线性矩阵的分组身份；重建上游Text::MakeFrom的绘制轮次顺序。
private struct TextAnimatorRunKey: Hashable {
    /// 一次文字整形中实际字体的下标。
    let fontIndex: Int
    /// 字形局部x轴映射到图层x的分量。
    let a: Double
    /// 字形局部x轴映射到图层y的分量。
    let b: Double
    /// 字形局部y轴映射到图层x的分量。
    let c: Double
    /// 字形局部y轴映射到图层y的分量。
    let d: Double
}

/// 在普通文字整形结果上逐帧施加tag70；轮廓和字体准备资源保持共享。
enum TextAnimatorPreparation {
    /// 顺序应用全部有效动画器并生成当帧矩阵/alpha；失败不发布部分文字资源。
    static func prepare(base: PreparedTextLayer, source: SourceText, animators: [SourceTextAnimator],
                        at frame: Int64, budget: inout FramePlanBudget) throws -> PreparedTextLayer {
        try Task.checkCancellation()
        guard !base.layout.glyphs.isEmpty,
              animators.contains(where: { $0.trackingAmount != nil || $0.position != nil
                  || $0.scale != nil || $0.rotation != nil || $0.opacity != nil }) else { return base }
        let initialCost = budget.used
        let count = base.layout.glyphs.count
        try budget.reserve(count: count, stride: 256)
        var glyphs = Array<PreparedTextGlyph?>(repeating: nil, count: count)
        var backgroundGlyphs = base.backgroundGlyphs
        guard backgroundGlyphs.isEmpty || backgroundGlyphs.count == count else {
            throw SceneValidator.invalid("textAnimatorLayoutIdentity")
        }
        for glyph in base.glyphs {
            try Task.checkCancellation()
            guard glyphs.indices.contains(glyph.layoutIndex), glyphs[glyph.layoutIndex] == nil else {
                throw SceneValidator.invalid("textAnimatorLayoutIdentity")
            }
            glyphs[glyph.layoutIndex] = glyph
        }
        for animator in animators {
            try Task.checkCancellation()
            // 上游HasAnimator只认排版/透明度属性；纯颜色子标签虽已解码却不改变字形。
            guard animator.trackingAmount != nil || animator.position != nil || animator.scale != nil
                    || animator.rotation != nil || animator.opacity != nil else { continue }
            let factors = try TextAnimatorSelectors.factors(animator.selectors, count: count, at: frame, budget: &budget)
            let tracking = try animator.trackingAmount.map { try PropertyEvaluation.scalar($0, at: frame) } ?? 0
            let trackingType = try animator.trackingType.map { try TextAnimatorSelectors.discreteByte($0, at: frame) } ?? 0
            let before = trackingType == 1 ? tracking : trackingType == 2 ? 0 : tracking * 0.5
            let after = trackingType == 2 ? tracking : trackingType == 1 ? 0 : tracking * 0.5
            let position = try animator.position.map { try PropertyEvaluation.point($0, at: frame) } ?? .zero
            let scale = try animator.scale.map { try PropertyEvaluation.point($0, at: frame) } ?? .one
            let rotation = try animator.rotation.map { try PropertyEvaluation.scalar($0, at: frame) } ?? 0
            let opacity = Double(try animator.opacity.map { try PropertyEvaluation.opacity($0, at: frame) } ?? 255) / 255
            for line in base.layout.lines {
                try Task.checkCancellation()
                let indices = line.glyphRange
                guard !indices.isEmpty else { continue }
                guard indices.lowerBound >= 0, indices.upperBound <= count else {
                    throw SceneValidator.invalid("textAnimatorLayoutIdentity")
                }
                var length = 0.0
                for index in indices {
                    let factor = Double(factors[index])
                    if index > indices.lowerBound { length += before * factor }
                    if index < indices.upperBound - 1 { length += after * factor }
                }
                guard length.isFinite else { throw SceneValidator.invalid("unrepresentableTextAnimatorTracking") }
                // 每行先量字距增量，再用段落对齐方式修正本行初始偏移。
                var offset = source.justification == 2 ? -length : source.justification == 0 ? 0 : -length * 0.5
                for index in indices {
                    try Task.checkCancellation()
                    let factor = Double(factors[index])
                    if index > indices.lowerBound { offset += before * factor }
                    let currentMatrix = backgroundGlyphs.isEmpty ? glyphs[index]?.matrix : backgroundGlyphs[index].matrix
                    if let currentMatrix {
                        var matrix = currentMatrix
                        matrix = try matrix.following(.translation(
                            x: source.direction == 2 ? 0 : offset,
                            y: source.direction == 2 ? offset : 0))
                        matrix = try matrix.following(.translation(x: position.x * factor, y: position.y * factor))
                        matrix = try SceneAffine.scale(x: (scale.x - 1) * factor + 1,
                                                       y: (scale.y - 1) * factor + 1).following(matrix)
                        matrix = try SceneAffine.rotation(degrees: rotation * factor).following(matrix)
                        // 负因子仍可反转几何变换，但透明度因子按上游先钳到零。
                        if let glyph = glyphs[index] {
                            let alpha = glyph.alpha * ((opacity - 1) * max(factor, 0) + 1)
                            guard alpha.isFinite, (0...1).contains(alpha) else {
                                throw SceneValidator.invalid("unrepresentableTextAnimatorAlpha")
                            }
                            glyphs[index] = PreparedTextGlyph(fill: glyph.fill, stroke: glyph.stroke,
                                matrix: matrix, alpha: alpha, layoutIndex: index, advance: glyph.advance,
                                fontIndex: glyph.fontIndex, cluster: glyph.cluster)
                        }
                        if !backgroundGlyphs.isEmpty {
                            let glyph = backgroundGlyphs[index]
                            backgroundGlyphs[index] = TextBackgroundGlyph(bounds: glyph.bounds,
                                matrix: matrix, advance: glyph.advance)
                        }
                    }
                    offset += after * factor
                }
            }
        }
        try budget.reserve(count: base.glyphs.count, stride: 256)
        var groups: [TextAnimatorRunKey: [PreparedTextGlyph]] = [:]
        var order: [TextAnimatorRunKey] = []
        for glyph in glyphs.compactMap({ $0 }) {
            try Task.checkCancellation()
            let matrix = glyph.matrix
            let key = TextAnimatorRunKey(fontIndex: glyph.fontIndex, a: matrix.a, b: matrix.b,
                                         c: matrix.c, d: matrix.d)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(glyph)
        }
        let arranged = order.flatMap { groups[$0] ?? [] }
        let cost = base.estimatedBytes.addingReportingOverflow(budget.used - initialCost)
        guard !cost.overflow else { throw PAGError.resourceLimitExceeded("maximumFramePlanBytes") }
        try Task.checkCancellation()
        return PreparedTextLayer(source: base.source, style: base.style, glyphs: arranged,
            passes: base.passes, layout: base.layout, layoutAdvances: base.layoutAdvances,
            backgroundGlyphs: backgroundGlyphs,
            fonts: base.fonts, missingGlyphIndices: base.missingGlyphIndices,
            estimatedBytes: cost.partialValue)
    }
}
