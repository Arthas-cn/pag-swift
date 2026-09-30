/// 固定PathKit的Float二次曲线值；供描边测量和偏移使用，不负责发布路径或近似为Cubic。
struct StrokeQuadCurve: Sendable {
    /// 原始起点；整段截取保留，不用Horner端点替换。
    let start: SIMD2<Float>
    /// 唯一二次控制点，允许与任一端点重合。
    let control: SIMD2<Float>
    /// 原始终点；可因Float舍入与position(1)不同。
    let end: SIMD2<Float>

    /// 保存三个有限控制点；非有限点报geometryPrecision，不提前建立可能溢出的系数。
    init(start: SIMD2<Float>, control: SIMD2<Float>, end: SIMD2<Float>) throws {
        self.start = try StrokeCurveMath.checked(start)
        self.control = try StrokeCurveMath.checked(control)
        self.end = try StrokeCurveMath.checked(end)
    }

    /// 在闭区间参数按源Float Horner求位置；端点也执行公式，不可表示结果明确失败。
    func position(at parameter: Float, budget: inout GeometryBudget) throws -> SIMD2<Float> {
        try budget.consume(32)
        try StrokeCurveMath.parameter(parameter)
        let a = try StrokeCurveMath.checked(end - 2 * control + start)
        let b = try StrokeCurveMath.checked(2 * (control - start))
        return try StrokeCurveMath.checked((a * parameter + b) * parameter + start)
    }

    /// 返回源原始方向，包括运算溢出的非有限分量；后续ray负责setLength失败回退。
    func tangent(at parameter: Float, budget: inout GeometryBudget) throws -> SIMD2<Float> {
        try budget.consume(32)
        try StrokeCurveMath.parameter(parameter)
        if (parameter == 0 && start == control) || (parameter == 1 && control == end) { return end - start }
        let b = control - start, a = end - control - b
        let value = a * parameter + b
        return value + value
    }

    /// 在严格内部参数切成两条共享中点的二次曲线；错误或取消不返回部分pair。
    func split(at parameter: Float, budget: inout GeometryBudget) throws -> (first: Self, second: Self) {
        try split(at: parameter, allowsEndpoints: false, budget: &budget)
    }

    /// 截取非空闭参数范围；整段直接保留，其他分支按源先截起点再归一化截终点。
    func segment(from lower: Float, to upper: Float, budget: inout GeometryBudget) throws -> Self {
        try budget.consume(32)
        try StrokeCurveMath.range(from: lower, to: upper)
        try budget.reserve(stride: 128)
        if lower == 0, upper == 1 { return self }
        let tail = lower == 0 ? self : try split(at: lower, budget: &budget).second
        guard upper < 1 else { return tail }
        let parameter = lower == 0 ? upper : (upper - lower) / (1 - lower)
        // 合法区间的归一参数可能舍入为1；仍执行chop公式，不能直接返回tail原端点。
        return try tail.split(at: parameter, allowsEndpoints: true, budget: &budget).first
    }

    /// 共享源de Casteljau步骤；仅segment内部允许舍入到端点，分配前完整计费。
    private func split(at parameter: Float, allowsEndpoints: Bool,
                       budget: inout GeometryBudget) throws -> (first: Self, second: Self) {
        try budget.consume(64)
        try StrokeCurveMath.parameter(parameter, interior: !allowsEndpoints)
        try budget.reserve(2, stride: 128)
        let first = try StrokeCurveMath.checked(start + (control - start) * parameter)
        let second = try StrokeCurveMath.checked(control + (end - control) * parameter)
        let middle = try StrokeCurveMath.checked(first + (second - first) * parameter)
        return try (Self(start: start, control: first, end: middle), Self(start: middle, control: second, end: end))
    }
}

/// Quad/Conic基础几何共同的参数与有限性门槛，不包含描边退化谓词或方向回退。
enum StrokeCurveMath {
    /// 单参数必须有限且位于指定开闭区间；错误与几何运算溢出区分。
    static func parameter(_ value: Float, interior: Bool = false) throws {
        guard value.isFinite, interior ? (value > 0 && value < 1) : (value >= 0 && value <= 1) else {
            throw PAGError.invalidArgument("strokeCurveParameter")
        }
    }

    /// 仅接受闭单位区间内的严格正跨度；零范围留给dash层追加精确零Line。
    static func range(from start: Float, to end: Float) throws {
        guard start.isFinite, end.isFinite, start >= 0, end <= 1, start < end else {
            throw PAGError.invalidArgument("strokeCurveRange")
        }
    }

    /// 位置、控制点与多项式系数必须有限；原始切线故意不经过此门槛。
    static func checked(_ point: SIMD2<Float>) throws -> SIMD2<Float> {
        guard point.x.isFinite, point.y.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        return point
    }

    /// 有理几何的分母、平方根和生成权重必须为有限正数；不把数值失败修补成直线。
    static func positive(_ value: Float) throws -> Float {
        guard value.isFinite, value > 0 else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        return value
    }
}
