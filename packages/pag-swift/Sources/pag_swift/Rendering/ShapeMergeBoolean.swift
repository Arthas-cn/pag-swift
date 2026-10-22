import CoreGraphics

/// 将已转换的形状路径交给系统路径布尔运算，并返回仍可供填充、描边和Trim使用的原生路径。
enum ShapeMergeBoolean {
    /// 按上游源序连续运算；开放轮廓由面积Boolean隐式闭合，Conic仍明确失败。
    static func make(_ inputs: [StrokePath], mode: SourceMergePathsMode,
                     budget: inout GeometryBudget) throws -> StrokePath {
        try budget.consume()
        guard inputs.count >= 2, mode != .merge else { throw PAGError.invalidArgument("mergePathsBooleanInputs") }
        var count = 0
        for input in inputs {
            try budget.consume()
            let sum = count.addingReportingOverflow(input.verbs.count)
            guard !sum.overflow else { throw PAGError.resourceLimitExceeded("maximumShapeBooleanSegments") }
            count = sum.partialValue
        }
        // CoreGraphics的同步布尔调用不可中途取消；先按交点二次上界收费并限制病理输入。
        guard count <= 1_024 else { throw PAGError.resourceLimitExceeded("maximumShapeBooleanSegments") }
        let work = count.multipliedReportingOverflow(by: count)
        guard !work.overflow else { throw PAGError.resourceLimitExceeded("maximumRenderGeometryWork") }
        let charged = work.partialValue.multipliedReportingOverflow(by: 4)
        guard !charged.overflow else { throw PAGError.resourceLimitExceeded("maximumRenderGeometryWork") }
        try budget.consume(charged.partialValue)
        try budget.reserve(count, stride: 96)
        var result = try cgPath(inputs[0], budget: &budget)
        for input in inputs.dropFirst() {
            try Task.checkCancellation()
            let next = try cgPath(input, budget: &budget)
            switch mode {
            case .add: result = result.union(next, using: .winding)
            case .subtract: result = result.subtracting(next, using: .winding)
            case .intersect: result = result.intersection(next, using: .winding)
            case .excludeIntersections: result = result.symmetricDifference(next, using: .winding)
            case .merge: throw PAGError.invalidArgument("mergePathsBooleanMode")
            }
            try Task.checkCancellation()
        }
        return try nativePath(result, budget: &budget)
    }

    /// 无损映射直线与Bezier控制点；开放轮廓交给填充Boolean，有理Conic尚无等价金值。
    private static func cgPath(_ source: StrokePath, budget: inout GeometryBudget) throws -> CGPath {
        let result = CGMutablePath()
        var index = 0
        for verb in source.verbs {
            try budget.consume()
            switch verb {
            case .move:
                result.move(to: point(source.points[index]))
            case .line:
                result.addLine(to: point(source.points[index]))
            case .quad:
                result.addQuadCurve(to: point(source.points[index + 1]),
                                    control: point(source.points[index]))
            case .cubic:
                result.addCurve(to: point(source.points[index + 2]),
                                control1: point(source.points[index]), control2: point(source.points[index + 1]))
            case .conic:
                throw PAGError.unsupportedFeature("mergePathsConicBoolean")
            case .close:
                result.closeSubpath()
            }
            index += verb.pointCount
        }
        return result
    }

    /// 把已校验的有限源点交给64位CGFloat路径API，不改动上游图层坐标。
    private static func point(_ value: ScenePoint) -> CGPoint {
        CGPoint(x: value.x, y: value.y)
    }

    /// 同步遍历布尔结果，逐元素限制留存量；任何异常都不发布部分StrokePath。
    private static func nativePath(_ source: CGPath, budget: inout GeometryBudget) throws -> StrokePath {
        var verbs: [StrokePathVerb] = []
        var points: [ScenePoint] = []
        var charged = budget
        var failure: Error?
        source.applyWithBlock { element in
            guard failure == nil else { return }
            do {
                try charged.consume()
                guard verbs.count < 16_384 else {
                    throw PAGError.resourceLimitExceeded("maximumShapeBooleanSegments")
                }
                try charged.reserve(stride: 32)
                let value = element.pointee
                let count: Int
                switch value.type {
                case .moveToPoint:
                    verbs.append(.move)
                    count = 1
                case .addLineToPoint:
                    verbs.append(.line)
                    count = 1
                case .addQuadCurveToPoint:
                    verbs.append(.quad)
                    count = 2
                case .addCurveToPoint:
                    verbs.append(.cubic)
                    count = 3
                case .closeSubpath:
                    verbs.append(.close)
                    count = 0
                @unknown default:
                    throw PAGError.unsupportedFeature("mergePathsCGElement")
                }
                try charged.reserve(count, stride: 32)
                for index in 0..<count {
                    try charged.consume()
                    let point = value.points[index]
                    guard point.x.isFinite, point.y.isFinite else {
                        throw PAGError.renderingFailure("mergePathsNonFinite")
                    }
                    points.append(ScenePoint(x: point.x, y: point.y))
                }
            } catch { failure = error }
        }
        budget = charged
        if let failure { throw failure }
        try Task.checkCancellation()
        return try StrokePath(verbs: verbs, points: points, budget: &budget)
    }
}
