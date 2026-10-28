/// Trim原生曲线进入普通Fill的最终出口；这里只生成填充折线，不回写裁剪拓扑。
extension PathFlattening {
    /// 按最终图层容差转换Conic并细分；误差一半给Conic近似，一半给曲线折线化。
    static func trimmedPath(_ path: StrokePath, tolerance: Double,
                            budget: inout GeometryBudget) throws -> [[ScenePoint]] {
        guard tolerance.isFinite, tolerance > 0 else { throw PAGError.invalidArgument("geometryTolerance") }
        let half = tolerance * 0.5
        guard half > 0 else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        var builder = FlattenedPathBuilder(budget: budget, tolerance: half)
        defer { budget = builder.budget }
        var current: ScenePoint?
        var index = 0
        for verb in path.verbs {
            try builder.budget.consume(1 + verb.pointCount)
            switch verb {
            case .move:
                try builder.finishContour()
                try builder.append(path.points[index])
                current = path.points[index]
            case .line:
                try builder.append(path.points[index])
                current = path.points[index]
            case .quad:
                try builder.curve(first: path.points[index], second: nil, end: path.points[index + 1])
                current = path.points[index + 1]
            case .conic(let weight):
                guard let start = current else { throw PAGError.renderingFailure("geometryPathSequence") }
                try builder.budget.reserve(stride: 512)
                let conic = StrokeConic(points: [start, path.points[index], path.points[index + 1]],
                                        weights: [1, Double(weight), 1])
                let cubics = try StrokeConicApproximation.cubics(conic, tolerance: half,
                    transform: .identity, budget: &builder.budget)
                for cubic in cubics {
                    try builder.curve(first: cubic.first, second: cubic.second, end: cubic.end)
                }
                // 当前位置必须取原端点，不能从Fill去重后的数组推导测量曲线位置。
                current = path.points[index + 1]
            case .cubic:
                try builder.curve(first: path.points[index], second: path.points[index + 1], end: path.points[index + 2])
                current = path.points[index + 2]
            case .close:
                try builder.finishContour()
                current = nil
            }
            index += verb.pointCount
        }
        try builder.finishContour()
        try Task.checkCancellation()
        return builder.contours
    }
}
