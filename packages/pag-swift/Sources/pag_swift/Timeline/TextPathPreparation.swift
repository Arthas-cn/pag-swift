import Foundation

/// 字体与新线性矩阵的分组身份；同一帧内按首现顺序完成上游文字轮次。
private struct TextPathRunKey: Hashable {
    /// 原准备资源的字体索引，不从系统字体名猜同一实例。
    let fontIndex: Int
    /// 字形局部x轴在文字图层中的横向系数。
    let a: Double
    /// 字形局部x轴在文字图层中的纵向系数。
    let b: Double
    /// 字形局部y轴在文字图层中的横向系数。
    let c: Double
    /// 字形局部y轴在文字图层中的纵向系数。
    let d: Double
}

/// 把静态整形资源按同层mask路径逐帧定位；失败不发布普通文字替身。
enum TextPathPreparation {
    /// 只重排字形矩阵并共享轮廓；路径引用缺失、无切线或超预算时抛出明确错误。
    static func prepare(base: PreparedTextLayer, source: SourceText, option: SourceTextPathOption,
                        masks: [SourceMask], at frame: Int64,
                        budget: inout FramePlanBudget) throws -> PreparedTextLayer {
        try Task.checkCancellation()
        // 上游MakeFrom对竖排返回nil，保留原文字资源而不伪造一条竖排切线路径。
        if source.direction == 2 { return base }
        guard option.maskID > 0, let mask = masks.first(where: { $0.id == option.maskID }) else {
            throw PAGError.unsupportedFeature("textPathReference")
        }
        let initialCost = budget.used
        let path = try PropertyEvaluation.path(mask.path, at: frame, budget: &budget)
        let reversed = try PropertyEvaluation.discreteBool(option.reversed, at: frame)
        let perpendicular = try PropertyEvaluation.discreteBool(option.perpendicular, at: frame)
        let force = try PropertyEvaluation.discreteBool(option.forceAlignment, at: frame)
        let firstMargin = try PropertyEvaluation.scalar(option.firstMargin, at: frame)
        let lastMargin = try PropertyEvaluation.scalar(option.lastMargin, at: frame)
        guard base.layoutAdvances.count == base.layout.glyphs.count else {
            throw SceneValidator.invalid("textPathLayoutIdentity")
        }
        try budget.reserve(count: base.layout.glyphs.count, stride: 256)
        let available = budget.limit - budget.used
        guard available > 0 else { throw PAGError.resourceLimitExceeded("maximumFramePlanBytes") }
        var geometryBudget = try GeometryBudget(maximumBytes: available)
        let geometry = try TextPathGeometry(path: path, reversed: reversed, budget: &geometryBudget)
        let xPositions = try positions(for: base, force: force, firstMargin: firstMargin,
                                       lastMargin: lastMargin, pathLength: Double(geometry.length))
        var byLayout = Array<PreparedTextGlyph?>(repeating: nil, count: base.layout.glyphs.count)
        for glyph in base.glyphs {
            try Task.checkCancellation()
            guard byLayout.indices.contains(glyph.layoutIndex), byLayout[glyph.layoutIndex] == nil else {
                throw SceneValidator.invalid("textPathLayoutIdentity")
            }
            byLayout[glyph.layoutIndex] = glyph
        }
        var groups: [TextPathRunKey: [PreparedTextGlyph]] = [:]
        var order: [TextPathRunKey] = []
        for index in base.layout.glyphs.indices {
            try geometryBudget.consume()
            guard let glyph = byLayout[index] else { continue }
            let position = base.layout.glyphs[index].position
            let half = glyph.advance * 0.5
            let distance = try mappedDistance(xPositions[index] + half, source: source,
                force: force, firstMargin: firstMargin, lastMargin: lastMargin,
                pathLength: Double(geometry.length))
            let sample = try geometry.sample(at: distance, budget: &geometryBudget)
            let linear = try SceneAffine(a: glyph.matrix.a, b: glyph.matrix.b,
                                         c: glyph.matrix.c, d: glyph.matrix.d, tx: 0, ty: 0)
            let matrix: SceneAffine
            if perpendicular {
                let degrees = atan2(sample.tangent.y, sample.tangent.x) * 180 / .pi
                // 上游preRotate是右乘局部矩阵，postTranslate再左乘平移；半推进量不预先旋转。
                let rotated = try SceneAffine.rotation(degrees: degrees).following(linear)
                matrix = try rotated.following(.translation(
                    x: sample.position.x - sample.tangent.y * position.y - half,
                    y: sample.position.y + sample.tangent.x * position.y))
            } else {
                matrix = try linear.following(.translation(
                    x: sample.position.x - half, y: sample.position.y + position.y))
            }
            let mapped = PreparedTextGlyph(fill: glyph.fill, stroke: glyph.stroke, matrix: matrix, alpha: glyph.alpha,
                layoutIndex: index, advance: glyph.advance, fontIndex: glyph.fontIndex, cluster: glyph.cluster)
            let key = TextPathRunKey(fontIndex: glyph.fontIndex, a: matrix.a, b: matrix.b,
                                     c: matrix.c, d: matrix.d)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(mapped)
        }
        try budget.reserve(stride: geometryBudget.usedBytes)
        let glyphs = order.flatMap { groups[$0] ?? [] }
        let cost = base.estimatedBytes.addingReportingOverflow(budget.used - initialCost)
        guard !cost.overflow else { throw PAGError.resourceLimitExceeded("maximumFramePlanBytes") }
        try Task.checkCancellation()
        return PreparedTextLayer(source: base.source, style: base.style, glyphs: glyphs,
            passes: base.passes, layout: base.layout, layoutAdvances: base.layoutAdvances,
            backgroundGlyphs: base.backgroundGlyphs,
            fonts: base.fonts, missingGlyphIndices: base.missingGlyphIndices,
            estimatedBytes: cost.partialValue)
    }

    /// 强制对齐忽略段落对齐，按行将全部真实推进量均摊到路径首尾距离。
    private static func positions(for base: PreparedTextLayer, force: Bool,
                                  firstMargin: Double, lastMargin: Double,
                                  pathLength: Double) throws -> [Double] {
        var result = base.layout.glyphs.map(\.position.x)
        guard force else { return result }
        let span = abs(pathLength + lastMargin - firstMargin)
        guard span.isFinite else { throw PAGError.resourceLimitExceeded("textPathDistance") }
        for line in base.layout.lines {
            try Task.checkCancellation()
            let count = line.glyphRange.count
            guard count > 0 else { continue }
            let total = base.layoutAdvances[line.glyphRange].reduce(0, +)
            let gaps = Double(count - 1)
            let spacing = gaps > 0 ? (firstMargin <= pathLength + lastMargin
                ? (span - total) / gaps : -(total + span) / gaps) : 0
            guard spacing.isFinite else { throw PAGError.resourceLimitExceeded("textPathDistance") }
            var x = 0.0
            for index in line.glyphRange {
                result[index] = x
                x += base.layoutAdvances[index] + spacing
            }
        }
        return result
    }

    /// 按上游左/右/中与强制对齐的优先级映射字形中心到路径距离。
    private static func mappedDistance(_ x: Double, source: SourceText, force: Bool,
                                       firstMargin: Double, lastMargin: Double,
                                       pathLength: Double) throws -> Double {
        let width = source.isBoxText ? source.boxSize.x : 0
        let value: Double
        if force || source.justification == 0 { value = x + firstMargin }
        else if source.justification == 2 { value = x - width + pathLength + lastMargin }
        else { value = x + (pathLength - width) * 0.5 + firstMargin + lastMargin }
        guard value.isFinite else { throw PAGError.resourceLimitExceeded("textPathDistance") }
        return value
    }
}
