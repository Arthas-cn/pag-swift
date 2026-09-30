/// 在后台准备作用域内完成整形、字形资源与纯值布局；系统对象不跨任何暂停点。
enum TextPreparation {
    /// 准备一份静态文本层；共享调用方预算，任何失败都不返回部分字形集合。
    static func prepare(_ source: SourceText, style: PAGText, budget: inout FramePlanBudget) throws -> PreparedTextLayer {
        try Task.checkCancellation()
        try style.validate()
        let initialCost = budget.used
        try budget.reserve(stride: 512)
        if !style.text.isEmpty && source.backgroundAlpha > 0 { throw PAGError.unsupportedFeature("textBackground") }
        let shaped = try CoreTextShaper.shape(style, budget: &budget)
        let clusters = try TextClusters(text: style.text, indices: shaped.glyphs.map(\.stringIndex), budget: &budget)
        try budget.reserve(count: shaped.glyphs.count, stride: 512)
        var cache: [TextGlyphKey: SystemGlyphGeometry] = [:]
        var inputs: [TextGlyphMetrics] = []
        var geometry: [SystemGlyphGeometry] = []
        var matrices: [SceneAffine] = []
        var missing: [Int] = []
        for (index, glyph) in shaped.glyphs.enumerated() {
            try Task.checkCancellation()
            let key = TextGlyphKey(fontIndex: glyph.fontIndex, glyphID: glyph.id)
            let resource: SystemGlyphGeometry
            if let existing = cache[key] { resource = existing }
            else {
                resource = try SystemGlyphGeometry.prepare(font: shaped.fonts[glyph.fontIndex], id: glyph.id,
                                                          source: source, style: style, budget: &budget)
                cache[key] = resource
            }
            let (metrics, matrix) = try resource.placementMetrics(cluster: clusters.cluster(at: glyph.stringIndex), vertical: source.direction == 2)
            inputs.append(metrics)
            geometry.append(resource)
            matrices.append(matrix)
            if glyph.id == 0 { missing.append(index) }
        }
        let layout = try TextLayout.layout(inputs, source: source, style: style, budget: &budget)
        let scale = try SceneAffine.scale(x: Double(layout.glyphScale), y: Double(layout.glyphScale))
        var groups: [TextRunKey: [PreparedTextGlyph]] = [:]
        var order: [TextRunKey] = []
        for placement in layout.glyphs {
            try Task.checkCancellation()
            let index = placement.glyphIndex
            let resource = geometry[index]
            guard !resource.fill.elements.isEmpty || !(resource.stroke?.elements.isEmpty ?? true) else { continue }
            let linear = try matrices[index].following(scale)
            let matrix = try linear.following(.translation(x: placement.position.x, y: placement.position.y))
            let fontIndex = shaped.glyphs[index].fontIndex
            let key = TextRunKey(fontIndex: fontIndex, a: matrix.a, b: matrix.b, c: matrix.c, d: matrix.d)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(PreparedTextGlyph(fill: resource.fill, stroke: resource.stroke, matrix: matrix,
                                                             fontIndex: fontIndex, cluster: try clusters.cluster(at: shaped.glyphs[index].stringIndex).range))
        }
        // 上游按 style 首次出现顺序分组；每轮先画完字体A的全部 glyph，再画字体B，不能按字逐轮混画。
        let glyphs = order.flatMap { groups[$0] ?? [] }
        var passes: [TextPaintPass] = []
        if let color = style.fillColor { passes.append(.fill(color)) }
        if let color = style.strokeColor, Float(style.strokeWidth) >= 0.1 { passes.append(.stroke(color)) }
        if !source.strokeOverFill { passes.reverse() }
        if glyphs.isEmpty { passes.removeAll() }
        try Task.checkCancellation()
        return PreparedTextLayer(style: style, glyphs: glyphs, passes: passes, layout: layout, fonts: shaped.fontInfo,
                                 missingGlyphIndices: missing, estimatedBytes: budget.used - initialCost)
    }
}

/// 同一次准备内的真实字体/glyph 缓存身份，不按相同文字片段错误复用上下文异形。
private struct TextGlyphKey: Hashable {
    /// 已按系统相等性去重的实际字体索引。
    let fontIndex: Int
    /// 该字体内的 glyph ID。
    let glyphID: UInt16
}

/// 静态文本的 style 分组键；平移不同不会拆分相同字体与字形线性变换。
private struct TextRunKey: Hashable {
    /// 准备结果中的实际字体索引。
    let fontIndex: Int
    /// 字形矩阵的 x→x 系数。
    let a: Double
    /// 字形矩阵的 x→y 系数。
    let b: Double
    /// 字形矩阵的 y→x 系数。
    let c: Double
    /// 字形矩阵的 y→y 系数。
    let d: Double
}
