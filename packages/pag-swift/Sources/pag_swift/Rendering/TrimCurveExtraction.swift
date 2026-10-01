/// SkContourMeasure的Float位置与逐段提取，保留独立Move和切片末点之间的源舍入差异。
enum TrimCurveExtraction {
    /// 为独立Move计算原曲线位置；Line/Cubic端点也执行Float公式，Quad/Conic用已有内核。
    static func point(on curve: StrokeDashCurve, at parameter: Float,
                      budget: inout GeometryBudget) throws -> ScenePoint {
        try budget.consume(32)
        try StrokeCurveMath.parameter(parameter)
        switch curve {
        case let .line(start, end):
            let first = try float(start), last = try float(end)
            return try scene(StrokeCurveMath.checked(first + (last - first) * parameter))
        case .quad, .conic:
            return try curve.point(at: parameter, budget: &budget)
        case let .cubic(start, first, second, end):
            try budget.reserve(4, stride: 16)
            let points = try [float(start), float(first), float(second), float(end)]
            return try scene(StrokeCubicAnalysis.position(points, at: parameter))
        }
    }

    /// 追加已定位的参数区间，零区间输出当前点；整段直通早于任何系数或Float切片构造。
    static func append(_ curve: StrokeDashCurve, from lower: Float, to upper: Float,
                       to writer: inout TrimPathWriter) throws {
        try writer.budget.consume()
        try StrokeCurveMath.parameter(lower)
        try StrokeCurveMath.parameter(upper)
        guard lower <= upper else { throw PAGError.invalidArgument("strokeCurveRange") }
        if lower == upper {
            try writer.appendZeroLengthLine()
            return
        }
        if lower == 0, upper == 1 {
            try appendWhole(curve, to: &writer)
            return
        }
        switch curve {
        case .line(_, let end):
            // segTo与Move位置不同：非零区间到t1时使用存储末点，不重算插值。
            let point = upper == 1 ? end : try point(on: curve, at: upper, budget: &writer.budget)
            try writer.append(.line, points: [point])
        case let .quad(start, control, end):
            let value = try StrokeQuadCurve(start: float(start), control: float(control), end: float(end))
            let part = try value.segment(from: lower, to: upper, budget: &writer.budget)
            try writer.append(.quad, points: [scene(part.control), scene(part.end)])
        case let .conic(start, control, end, weight):
            let value = try StrokeConicCurve(start: float(start), control: float(control), end: float(end), weight: weight)
            let part = try value.segment(from: lower, to: upper, budget: &writer.budget)
            try writer.append(.conic(weight: part.weight), points: [scene(part.control), scene(part.end)])
        case let .cubic(start, first, second, end):
            let value = try TrimCubicCurve(start: float(start), first: float(first), second: float(second), end: float(end))
            let part = try value.segment(from: lower, to: upper, budget: &writer.budget)
            // 外层Move取自原曲线Horner；不能用part.start或position(upper)把端点“修齐”。
            try writer.append(.cubic, points: [scene(part.first), scene(part.second), scene(part.end)])
        }
    }

    /// 复制原有控制点与终点，不写起点或Close；完整区间无需建立可能溢出的Horner系数。
    private static func appendWhole(_ curve: StrokeDashCurve, to writer: inout TrimPathWriter) throws {
        switch curve {
        case let .line(_, end): try writer.append(.line, points: [end])
        case let .quad(_, control, end): try writer.append(.quad, points: [control, end])
        case let .conic(_, control, end, weight): try writer.append(.conic(weight: weight), points: [control, end])
        case let .cubic(_, first, second, end): try writer.append(.cubic, points: [first, second, end])
        }
    }

    /// 仅接受能表示为有限源Float的点；不以截断、零或直线补偿失败。
    private static func float(_ point: ScenePoint) throws -> SIMD2<Float> {
        try StrokeCurveMath.checked(SIMD2(Float(point.x), Float(point.y)))
    }

    /// 将已完成源Float运算的点提升为后台曲线存储，不再次计算位置。
    private static func scene(_ point: SIMD2<Float>) -> ScenePoint {
        ScenePoint(x: Double(point.x), y: Double(point.y))
    }
}
