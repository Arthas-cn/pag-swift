/// 将普通蒙版的源路径交给既有纯Swift描边后端；只生成当前项的描边轮廓，不做外层蒙版布尔。
enum MaskExpansionGeometry {
    /// 按上游Float宽度生成Butt/Round描边；无法保持PathKit指令语义时明确失败。
    static func strokeContours(for path: SourcePath, expansion: Float, original: [[ScenePoint]],
                               tolerance: Double, budget: inout GeometryBudget) throws -> [[ScenePoint]] {
        try budget.consume()
        guard expansion.isFinite else { throw PAGError.invalidArgument("maskExpansion") }
        guard expansion != 0 else { return [] }
        let width = abs(expansion) * 2
        guard width.isFinite, Double(width) <= StrokeBackendLimits.standard.maximumMagnitude else {
            throw PAGError.resourceLimitExceeded("maximumStrokeMagnitude")
        }
        // TGFX的hairline提前返回原路径副本，但PathUtil仍在外层做正并/负差。
        if width <= 1.0 / 4096 { return original }
        guard tolerance.isFinite, tolerance > 0, (tolerance * 0.5) > 0 else {
            throw PAGError.resourceLimitExceeded("geometryPrecision")
        }
        let partialTolerance = tolerance * 0.5
        var builder = StrokePathBuilder(budget: budget, limits: .standard)
        defer { budget = builder.budget }
        var pointIndex = 0
        var isOpen = false
        for verb in path.verbs {
            try builder.budget.consume()
            switch verb {
            case .move:
                try builder.append(.move, points: [path.points[pointIndex]])
                pointIndex += 1
                isOpen = true
            case .line:
                // PathKit会隐式补Move；现有StrokePath不接受该次序，未经等价证明不能猜起点。
                guard isOpen else { throw PAGError.unsupportedFeature("maskExpansionPathSequence") }
                try builder.append(.line, points: [path.points[pointIndex]])
                pointIndex += 1
            case .cubic:
                guard isOpen else { throw PAGError.unsupportedFeature("maskExpansionPathSequence") }
                try builder.append(.cubic, points: Array(path.points[pointIndex..<(pointIndex + 3)]))
                pointIndex += 3
            case .close:
                // PathKit在空路径及重复Close上不追加verb；它们仍可占据蒙版源顺序。
                guard isOpen else { continue }
                try builder.append(.close)
                isOpen = false
            }
        }
        let centerline = try builder.finish()
        let style = StrokeStyle(width: Double(width), cap: .butt, join: .round,
                                miterLimit: 4, dashes: nil)
        let outline = try StrokeOutline.make(centerline, style: style,
                                             tolerance: partialTolerance, budget: &builder.budget)
        return try PathFlattening.sourcePath(outline, tolerance: partialTolerance, budget: &builder.budget)
    }
}
