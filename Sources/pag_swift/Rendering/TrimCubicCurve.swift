/// Trim专用源Float三次切片值；不修改已有Stroke的Double截取合同。
struct TrimCubicCurve {
    /// 单段原起点，不以Horner端点反求。
    let start: SIMD2<Float>
    /// 第一控制点，允许退化或与起点重合。
    let first: SIMD2<Float>
    /// 第二控制点，允许退化或与终点重合。
    let second: SIMD2<Float>
    /// 单段原终点，整段或t1切分时直接保留。
    let end: SIMD2<Float>

    /// 保存四个有限Float点，输入或算术不可表示沿用共享几何内核错误。
    init(start: SIMD2<Float>, first: SIMD2<Float>, second: SIMD2<Float>, end: SIMD2<Float>) throws {
        self.start = try StrokeCurveMath.checked(start)
        self.first = try StrokeCurveMath.checked(first)
        self.second = try StrokeCurveMath.checked(second)
        self.end = try StrokeCurveMath.checked(end)
    }

    /// 源SkContourMeasure先截起点，再按Float归一参数截终点；非空单位范围外失败。
    func segment(from lower: Float, to upper: Float, budget: inout GeometryBudget) throws -> Self {
        try budget.consume()
        try StrokeCurveMath.range(from: lower, to: upper)
        if lower == 0, upper == 1 { return self }
        let tail = lower == 0 ? self : try split(at: lower, budget: &budget).second
        guard upper < 1 else { return tail }
        let parameter = lower == 0 ? upper : (upper - lower) / (1 - lower)
        return try tail.split(at: parameter, budget: &budget).first
    }

    /// 单参数SkChopCubicAt，六次Float插值；t1保留原四点，不以通用公式改变末点舍入。
    func split(at parameter: Float, budget: inout GeometryBudget) throws -> (first: Self, second: Self) {
        try budget.consume(64)
        try StrokeCurveMath.parameter(parameter)
        try budget.reserve(2, stride: 128)
        if parameter == 1 {
            return try (self, Self(start: end, first: end, second: end, end: end))
        }
        let a = try StrokeCurveMath.checked((first - start) * parameter + start)
        let b = try StrokeCurveMath.checked((second - first) * parameter + first)
        let c = try StrokeCurveMath.checked((end - second) * parameter + second)
        let d = try StrokeCurveMath.checked((b - a) * parameter + a)
        let e = try StrokeCurveMath.checked((c - b) * parameter + b)
        let middle = try StrokeCurveMath.checked((e - d) * parameter + d)
        return try (Self(start: start, first: a, second: d, end: middle),
                    Self(start: middle, first: e, second: c, end: end))
    }
}
