/// Quad/Conic的源描边分类；降阶仅保留一个回折点，不包含Cubic的多根或cusp语义。
enum StrokeQuadraticReduction: Sendable {
    /// 两条控制边都严格为零，仍须交给无前瞻Line处理可能的端帽。
    case point
    /// 直接连接原终点；控制边重复或曲率参数端点满足各自类型规则时使用。
    case line
    /// 唯一回折点，随后到原终点的内部连接临时使用Round；允许点恰等于原终点。
    case reversal(point: SIMD2<Float>)
    /// 真正曲线，后续以原控制点建立首切线并分别计算两侧偏移。
    case curve
}

/// 固定CheckQuadLinear/CheckConicLinear的Float分析，不负责修改接受点或生成边界。
enum StrokeQuadraticAnalysis {
    /// 分类二次曲线；最大曲率参数为0或1都降Line，数值或预算失败直接抛出。
    static func reduction(of curve: StrokeQuadCurve, budget: inout GeometryBudget) throws -> StrokeQuadraticReduction {
        try reduction(start: curve.start, control: curve.control, end: curve.end,
                      keepsUpperEndpoint: false, budget: &budget) { parameter, sharedBudget in
            try curve.position(at: parameter, budget: &sharedBudget)
        }
    }

    /// 分类有理曲线；普通Quad参数等于1时仍求原Conic位置并保留reversal。
    static func reduction(of curve: StrokeConicCurve, budget: inout GeometryBudget) throws -> StrokeQuadraticReduction {
        try reduction(start: curve.start, control: curve.control, end: curve.end,
                      keepsUpperEndpoint: true, budget: &budget) { parameter, sharedBudget in
            try curve.position(at: parameter, budget: &sharedBudget)
        }
    }

    /// 共用三点分类，只有回折点位置由各自原曲线求值；同步闭包不跨隔离或保存预算副本。
    private static func reduction(start: SIMD2<Float>, control: SIMD2<Float>, end: SIMD2<Float>,
                                  keepsUpperEndpoint: Bool, budget: inout GeometryBudget,
                                  position: (Float, inout GeometryBudget) throws -> SIMD2<Float>) throws -> StrokeQuadraticReduction {
        try budget.consume(64)
        let ab = try StrokeCurveMath.checked(control - start), bc = try StrokeCurveMath.checked(end - control)
        if ab == .zero && bc == .zero { return .point }
        if ab == .zero || bc == .zero { return .line }
        guard try isNearlyLinear(start, control, end, ab: ab, bc: bc) else { return .curve }
        let b = try StrokeCurveMath.checked(((start - control) - control) + end)
        let numerator = -(ab.x * b.x + ab.y * b.y), denominator = b.x * b.x + b.y * b.y
        guard numerator.isFinite, denominator.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        let parameter: Float
        // 源先判断numer<=0，再判断numer>=denom；零分母不直接执行除法。
        if numerator <= 0 { parameter = 0 }
        else if numerator >= denominator { parameter = 1 }
        else { parameter = numerator / denominator }
        if parameter == 0 || (parameter == 1 && !keepsUpperEndpoint) { return .line }
        return try .reversal(point: position(parameter, &budget))
    }

    /// 首个最大L∞点对决定投影基线；相等跨度不替换，slop保留源Float乘法次序。
    private static func isNearlyLinear(_ start: SIMD2<Float>, _ control: SIMD2<Float>, _ end: SIMD2<Float>,
                                       ab: SIMD2<Float>, bc: SIMD2<Float>) throws -> Bool {
        let ac = try StrokeCurveMath.checked(end - start)
        var maximum = max(abs(ab.x), abs(ab.y))
        var first = start, last = control, middle = end
        let across = max(abs(ac.x), abs(ac.y)), second = max(abs(bc.x), abs(bc.y))
        if maximum < across { maximum = across; first = start; last = end; middle = control }
        if maximum < second { maximum = second; first = control; last = end; middle = start }
        let slop = (maximum * maximum) * Float(0.000005)
        // pt_to_line的0/0投影按源落到lineStart距离；只验证实际返回距离，不额外拒绝该默认分支。
        let distance = StrokeOffsetQuad.distanceSquared(middle, from: first, to: last)
        guard slop.isFinite, distance.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        return distance <= slop
    }
}
