/// 固定PathKit的Float有理二次曲线；首末权重隐含为1，与Double出口近似器各司其职。
struct StrokeConicCurve: Sendable {
    /// 原始起点；整段及单参数左段保留其原Float值。
    let start: SIMD2<Float>
    /// 有理曲线控制点，与weight一起决定位置和参数速度。
    let control: SIMD2<Float>
    /// 原始终点；整段及单参数右段保留，不从Horner反推。
    let end: SIMD2<Float>
    /// 有限正中间权重；截取后允许为1，发布StrokePath时才归为Quad。
    let weight: Float

    /// 保存有限点与正有限权重，不急切计算系数；非法权重和点不可表示分别报不同错误。
    init(start: SIMD2<Float>, control: SIMD2<Float>, end: SIMD2<Float>, weight: Float) throws {
        guard weight.isFinite, weight > 0 else { throw PAGError.invalidArgument("strokeConicWeight") }
        self.start = try StrokeCurveMath.checked(start)
        self.control = try StrokeCurveMath.checked(control)
        self.end = try StrokeCurveMath.checked(end)
        self.weight = weight
    }

    /// 在闭区间参数按源分子/分母Horner求位置；不添加端点快路，分母失效明确失败。
    func position(at parameter: Float, budget: inout GeometryBudget) throws -> SIMD2<Float> {
        try budget.consume(32)
        try StrokeCurveMath.parameter(parameter)
        let value = try StrokeConicCoefficients(self).value(at: parameter)
        return try StrokeCurveMath.checked(value.numerator / value.denominator)
    }

    /// 返回源未归一方向，可含运算产生的非有限值；调用方ray必须保留setLength的失败回退。
    func tangent(at parameter: Float, budget: inout GeometryBudget) throws -> SIMD2<Float> {
        try budget.consume(32)
        try StrokeCurveMath.parameter(parameter)
        if (parameter == 0 && start == control) || (parameter == 1 && control == end) { return end - start }
        let p20 = end - start, p10 = control - start
        let c = weight * p10, a = weight * p20 - p20, b = p20 - c - c
        return (a * parameter + b) * parameter + c
    }

    /// 在严格内部参数按源齐次Float步骤切分；左右共享一次投影中点，不返回残缺pair。
    func split(at parameter: Float, budget: inout GeometryBudget) throws -> (first: Self, second: Self) {
        try budget.consume(64)
        try StrokeCurveMath.parameter(parameter, interior: true)
        try budget.reserve(2, stride: 128)
        let a = SIMD3(start.x, start.y, 1), c = SIMD3(end.x, end.y, 1)
        let b = SIMD3(control.x * weight, control.y * weight, weight)
        let ab = a + (b - a) * parameter, bc = b + (c - b) * parameter
        let mid = ab + (bc - ab) * parameter
        let firstControl = try project(ab), secondControl = try project(bc), middle = try project(mid)
        let root = try StrokeCurveMath.positive(mid.z).squareRoot()
        let firstWeight = try StrokeCurveMath.positive(ab.z / root)
        let secondWeight = try StrokeCurveMath.positive(bc.z / root)
        return try (Self(start: start, control: firstControl, end: middle, weight: firstWeight),
                    Self(start: middle, control: secondControl, end: end, weight: secondWeight))
    }

    /// 保留整段或按端参数选择单切分；严格内部范围按原系数重建，不能套用两次仿射参数切分。
    func segment(from lower: Float, to upper: Float, budget: inout GeometryBudget) throws -> Self {
        try budget.consume(32)
        try StrokeCurveMath.range(from: lower, to: upper)
        try budget.reserve(stride: 128)
        if lower == 0, upper == 1 { return self }
        if lower == 0 { return try split(at: upper, budget: &budget).first }
        if upper == 1 { return try split(at: lower, budget: &budget).second }
        let coefficients = try StrokeConicCoefficients(self)
        let a = try coefficients.value(at: lower), c = try coefficients.value(at: upper)
        // 这里只用中点重建控制值，不递归；即使Float中点舍到边界也继续源公式。
        let d = try coefficients.value(at: (lower + upper) / 2)
        let bNumerator = try StrokeCurveMath.checked(2 * d.numerator - (a.numerator + c.numerator) * 0.5)
        let bDenominator = try StrokeCurveMath.positive(2 * d.denominator - (a.denominator + c.denominator) * 0.5)
        let product = try StrokeCurveMath.positive(a.denominator * c.denominator)
        let newWeight = try StrokeCurveMath.positive(bDenominator / product.squareRoot())
        return try Self(start: a.numerator / a.denominator, control: bNumerator / bDenominator,
                        end: c.numerator / c.denominator, weight: newWeight)
    }

    /// 齐次插值必须先验证数值再投影；不能用非有限除法产生的偶然有限点掩盖失败。
    private func project(_ point: SIMD3<Float>) throws -> SIMD2<Float> {
        let numerator = try StrokeCurveMath.checked(SIMD2(point.x, point.y))
        return try StrokeCurveMath.checked(numerator / StrokeCurveMath.positive(point.z))
    }
}

/// 延后建立的源Horner系数；仅位置与内部区间截取需要它，整段或单参数切分不依赖此表示。
private struct StrokeConicCoefficients {
    /// 分子二次项，保留源P2-2*P1w+P0的Float次序。
    let a: SIMD2<Float>
    /// 分子一次项，源2*(P1w-P0)。
    let b: SIMD2<Float>
    /// 分子常量项，即原P0。
    let c: SIMD2<Float>
    /// 分母一次项，二次项是0减此值，常量是1。
    let denominatorB: Float

    /// 只接受可表示的系数；不能因这里失败而禁止不需要系数的单参数切分。
    init(_ curve: StrokeConicCurve) throws {
        let weighted = try StrokeCurveMath.checked(curve.control * curve.weight)
        a = try StrokeCurveMath.checked(curve.end - 2 * weighted + curve.start)
        b = try StrokeCurveMath.checked(2 * (weighted - curve.start))
        c = curve.start
        denominatorB = 2 * (curve.weight - 1)
        guard denominatorB.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
    }

    /// 同一全局参数分别计算分子分母；分母必须有限正，调用方才可执行投影或控制点重建。
    func value(at parameter: Float) throws -> (numerator: SIMD2<Float>, denominator: Float) {
        let numerator = try StrokeCurveMath.checked((a * parameter + b) * parameter + c)
        let denominator = try StrokeCurveMath.positive(((0 - denominatorB) * parameter + denominatorB) * parameter + 1)
        return (numerator, denominator)
    }
}
