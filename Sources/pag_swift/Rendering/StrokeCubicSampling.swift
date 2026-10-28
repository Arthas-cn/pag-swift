/// 一个全局参数上的源曲线位置、偏移位置与切线绝对点，不持有平台资源。
struct StrokeOffsetRay: Sendable {
    /// 原曲线的Float全局参数位置，补切线不能改变它。
    let curve: SIMD2<Float>
    /// 在指定侧按半宽偏移的点。
    let offset: SIMD2<Float>
    /// offset加已缩放切向；是绝对点而非单位向量。
    let tangent: SIMD2<Float>
}

/// 固定PathKit的Cubic偏移采样及分段分析；只处理全局参数，不重参数化原曲线。
enum StrokeCubicSampling {
    /// 四点、0...1参数、正半径与±1侧别生成ray；非法参数或不可表示几何明确抛出。
    static func ray(_ points: [SIMD2<Float>], at parameter: Float, radius: Float,
                    side: Float, budget: inout GeometryBudget) throws -> StrokeOffsetRay {
        try validate(points, budget: &budget)
        guard parameter.isFinite, (0...1).contains(parameter), radius.isFinite, radius > 0,
              side == 1 || side == -1 else { throw PAGError.invalidArgument("strokeCubicSampling") }
        let curve = try StrokeCubicAnalysis.position(points, at: parameter)
        var direction = derivative(points, at: parameter)
        if parameter == 0, points[0] == points[1] { direction = points[2] - points[0] }
        else if parameter == 1, points[2] == points[3] { direction = points[3] - points[1] }
        if (parameter == 0 && points[0] == points[1]) || (parameter == 1 && points[2] == points[3]), direction == .zero {
            direction = points[3] - points[0]
        }
        if direction == .zero {
            var chord = points[3] - points[0]
            if abs(parameter) <= 1.0 / 4096 { direction = points[2] - points[0] }
            else if abs(1 - parameter) <= 1.0 / 4096 { direction = points[3] - points[1] }
            else {
                // 只借左半控制多边形恢复方向，curve仍保留原四点的Horner结果。
                let ab = (points[1] - points[0]) * parameter + points[0]
                let bc = (points[2] - points[1]) * parameter + points[1]
                let cd = (points[3] - points[2]) * parameter + points[2]
                let abc = (bc - ab) * parameter + ab, bcd = (cd - bc) * parameter + bc
                let middle = (bcd - abc) * parameter + abc
                direction = middle - abc
                if direction == .zero {
                    direction = middle - ab
                    chord = middle - points[0]
                }
            }
            if direction == .zero { direction = chord }
        }
        // 源setRayPts直接setLength(radius)，不能先Float单位化后乘radius。
        let scaled = StrokeLineMath.scaled(direction, length: radius) ?? SIMD2(radius, 0)
        let offset = SIMD2(curve.x + side * scaled.y, curve.y - side * scaled.x)
        let tangent = offset + scaled
        try finite(offset)
        try finite(tangent)
        return StrokeOffsetRay(curve: curve, offset: offset, tangent: tangent)
    }

    /// 返回至多两个开区间拐点，顺序用于划分原四点的全局t，失败不伪装为无拐点。
    static func inflections(_ points: [SIMD2<Float>], budget: inout GeometryBudget) throws -> [Float] {
        try validate(points, budget: &budget)
        let a = points[1] - points[0], b = points[2] - 2 * points[1] + points[0]
        let c = points[3] + 3 * (points[1] - points[2]) - points[0]
        return try StrokeCubicPolynomial.quadraticRoots(cross(b, c), cross(a, c), cross(a, b), budget: &budget)
    }

    /// 取首个原始导数近零的内部曲率候选；nil为源规则无cusp，不代表数值失败。
    static func cusp(_ points: [SIMD2<Float>], budget: inout GeometryBudget) throws -> Float? {
        try validate(points, budget: &budget)
        if points[0] == points[1] || points[2] == points[3] { return nil }
        for (test, line) in [(0, 2), (2, 0)] {
            let origin = points[line], direction = points[line + 1] - origin
            // Float负乘积下溢为−0仍会拒绝；不能只比较两个叉积的符号。
            if cross(direction, points[test] - origin) * cross(direction, points[test + 1] - origin) >= 0 { return nil }
        }
        let roots = try StrokeCubicAnalysis.curvatureParameters(points, budget: &budget)
        let precision = (squared(points[1] - points[0]) + squared(points[2] - points[1])
                         + squared(points[3] - points[2])) * Float(1e-8)
        guard precision.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        for root in roots where root > 0 && root < 1 {
            let magnitude = squared(derivative(points, at: root))
            guard magnitude.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
            if magnitude < precision { return root }
        }
        return nil
    }

    /// 原F′/3，不包含端点或零导数补救；调用方已验证四点及参数。
    static func derivative(_ points: [SIMD2<Float>], at t: Float) -> SIMD2<Float> {
        let a = points[3] + 3 * (points[1] - points[2]) - points[0]
        let b = 2 * (points[2] - 2 * points[1] + points[0]), c = points[1] - points[0]
        return (a * t + b) * t + c
    }

    /// Float平方长度，用于源阈值而非setLength的Double归一化。
    static func squared(_ vector: SIMD2<Float>) -> Float { vector.x * vector.x + vector.y * vector.y }

    /// 固定Float叉积次序，不能改为Double或融合乘加。
    static func cross(_ first: SIMD2<Float>, _ second: SIMD2<Float>) -> Float { first.x * second.y - first.y * second.x }

    /// 有界成本校验四点；非有限数据不会进入求根或射线计算。
    private static func validate(_ points: [SIMD2<Float>], budget: inout GeometryBudget) throws {
        try budget.consume(32)
        guard points.count == 4 else { throw PAGError.invalidArgument("strokeCubicPoints") }
        for point in points { try finite(point) }
    }

    /// 应保留或输出的点必须可表示；源显式退化谓词不借此提前改变分支。
    private static func finite(_ point: SIMD2<Float>) throws {
        guard point.x.isFinite, point.y.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
    }
}
