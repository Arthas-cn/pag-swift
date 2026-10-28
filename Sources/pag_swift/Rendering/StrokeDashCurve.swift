/// 虚线测量记录对应的原曲线；Double存储保留控制点，Quad/Conic仅在采样或部分截取时进入Float内核。
enum StrokeDashCurve: Sendable {
    /// 一条直线；start可能是源码compact规则保留的上一段终点。
    case line(start: ScenePoint, end: ScenePoint)
    /// 原二次曲线；完整提取保留control/end，部分提取遵循源Float步骤。
    case quad(start: ScenePoint, control: ScenePoint, end: ScenePoint)
    /// 原有理二次曲线；weight是有限正源Float值，截取后的单位权重由输出器规范化。
    case conic(start: ScenePoint, control: ScenePoint, end: ScenePoint, weight: Float)
    /// 原三次曲线；保留既有Double截取，不把测量叶弦当成输出。
    case cubic(start: ScenePoint, first: ScenePoint, second: ScenePoint, end: ScenePoint)

    /// 当前提取起点；测量时的原起点可能因compact规则而不同。
    var start: ScenePoint {
        switch self {
        case let .line(start, _), let .quad(start, _, _), let .conic(start, _, _, _), let .cubic(start, _, _, _): start
        }
    }

    /// 原曲线存储终点，不由最后一条增长测量记录的参数重算。
    var end: ScenePoint {
        switch self {
        case let .line(_, end), let .quad(_, _, end), let .conic(_, _, end, _), let .cubic(_, _, _, end): end
        }
    }

    /// 仅替换输出起点；测量已经完成，控制点、末点和权重保持原值。
    func replacingStart(with value: ScenePoint) -> Self {
        switch self {
        case let .line(_, end): .line(start: value, end: end)
        case let .quad(_, control, end): .quad(start: value, control: control, end: end)
        case let .conic(_, control, end, weight): .conic(start: value, control: control, end: end, weight: weight)
        case let .cubic(_, first, second, end): .cubic(start: value, first: first, second: second, end: end)
        }
    }

    /// 生成独立Move位置；Quad/Conic包括0/1都走Float Horner，非法参数或数值不可表示明确失败。
    func point(at parameter: Float, budget: inout GeometryBudget) throws -> ScenePoint {
        try budget.consume()
        try StrokeCurveMath.parameter(parameter)
        switch self {
        case let .line(start, end):
            if parameter == 0 { return start }
            if parameter == 1 { return end }
            return Self.mix(start, end, Double(parameter))
        case let .quad(start, control, end):
            let curve = try StrokeQuadCurve(start: Self.float(start), control: Self.float(control), end: Self.float(end))
            return Self.scene(try curve.position(at: parameter, budget: &budget))
        case let .conic(start, control, end, weight):
            let curve = try StrokeConicCurve(start: Self.float(start), control: Self.float(control), end: Self.float(end), weight: weight)
            return Self.scene(try curve.position(at: parameter, budget: &budget))
        case let .cubic(start, first, second, end):
            if parameter == 0 { return start }
            if parameter == 1 { return end }
            return Self.splitCubic(start: start, first: first, second: second, end: end, at: parameter).first.end
        }
    }

    /// 提取合法参数范围；零范围复制当前点，整段直通存储值，部分Quad/Conic截取后仍保留曲线类型。
    func append(from start: Float, to end: Float, to output: StrokeDashOutput) throws {
        try output.budget.consume()
        guard start.isFinite, end.isFinite, start >= 0, end <= 1, start <= end else {
            throw PAGError.resourceLimitExceeded("geometryPrecision")
        }
        if start == end {
            try output.appendZeroLengthLine()
            return
        }
        // 源segTo整段直接写原控制点；必须早于Float helper构造，避免多一次量化。
        if start == 0, end == 1 {
            try appendWhole(to: output)
            return
        }
        switch self {
        case .line:
            let point = try point(at: end, budget: &output.budget)
            try output.append(.line, points: [point])
        case let .quad(first, control, last):
            let curve = try StrokeQuadCurve(start: Self.float(first), control: Self.float(control), end: Self.float(last))
            let part = try curve.segment(from: start, to: end, budget: &output.budget)
            // Move由外层独立采样；segment.start可能与之不同，不能再补点修齐。
            try output.append(.quad, points: [Self.scene(part.control), Self.scene(part.end)])
        case let .conic(first, control, last, weight):
            let curve = try StrokeConicCurve(start: Self.float(first), control: Self.float(control), end: Self.float(last), weight: weight)
            let part = try curve.segment(from: start, to: end, budget: &output.budget)
            try output.append(.conic(weight: part.weight), points: [Self.scene(part.control), Self.scene(part.end)])
        case let .cubic(firstPoint, first, second, last):
            var selected = start == 0 ? self : Self.splitCubic(start: firstPoint, first: first, second: second, end: last, at: start).second
            if end < 1, case let .cubic(a, b, c, d) = selected {
                // 源先截去起始部分，再用Float归一参数截终点；三次控制点仍按既定Double计算。
                let parameter = start == 0 ? end : (end - start) / (1 - start)
                guard parameter.isFinite, parameter >= 0, parameter <= 1 else {
                    throw PAGError.resourceLimitExceeded("geometryPrecision")
                }
                selected = Self.splitCubic(start: a, first: b, second: c, end: d, at: parameter).first
            }
            try selected.appendWhole(to: output)
        }
    }

    /// 写出已选择曲线的控制点与末点；不写起点，不新增Float边界或近似转换。
    private func appendWhole(to output: StrokeDashOutput) throws {
        switch self {
        case let .line(_, end): try output.append(.line, points: [end])
        case let .quad(_, control, end): try output.append(.quad, points: [control, end])
        case let .conic(_, control, end, weight): try output.append(.conic(weight: weight), points: [control, end])
        case let .cubic(_, first, second, end): try output.append(.cubic, points: [first, second, end])
        }
    }

    /// 按既定Double de Casteljau切三次曲线，返回共享分割点的左右原类型值。
    private static func splitCubic(start: ScenePoint, first: ScenePoint, second: ScenePoint, end: ScenePoint,
                                   at parameter: Float) -> (first: Self, second: Self) {
        let t = Double(parameter)
        let a = mix(start, first, t), b = mix(first, second, t), c = mix(second, end, t)
        let d = mix(a, b, t), e = mix(b, c, t)
        let middle = mix(d, e, t)
        return (.cubic(start: start, first: a, second: d, end: middle),
                .cubic(start: middle, first: e, second: c, end: end))
    }

    /// 与既有Line/Cubic顺序一致的Double插值；参数由调用方验证。
    private static func mix(_ first: ScenePoint, _ second: ScenePoint, _ t: Double) -> ScenePoint {
        ScenePoint(x: first.x + (second.x - first.x) * t, y: first.y + (second.y - first.y) * t)
    }

    /// 构造消费期Float影子；Double有限但Float溢出的输入也明确失败。
    private static func float(_ value: ScenePoint) throws -> SIMD2<Float> {
        try StrokeCurveMath.checked(SIMD2(Float(value.x), Float(value.y)))
    }

    /// 仅提升已完成源Float运算的结果，不重新求值或修改原存储曲线。
    private static func scene(_ value: SIMD2<Float>) -> ScenePoint {
        ScenePoint(x: Double(value.x), y: Double(value.y))
    }
}
