/// 描边Cubic的源码分类；点与线消费相同，但区分它们以验证退化条件。
enum StrokeCubicReduction: Sendable {
    /// 三个相邻控制向量都退化，仍交给无前瞻lineTo处理端帽。
    case point
    /// 源判断可直接连接终点，不保留原参数速度。
    case line
    /// 一至三个按参数排序的内部转折点，后续内部连接临时使用Round。
    case polyline([SIMD2<Float>])
    /// 真正非线性曲线，关联值为源首切向控制点，不能当成二次曲线降阶。
    case curve(startTangent: SIMD2<Float>)
}

/// 固定CheckCubicLinear的Float分析，P0必须来自描边最后接受点而非原始路径游标。
enum StrokeCubicAnalysis {
    /// 接受四个有限Float控制点；返回源降阶结果，数值/结构/预算失败不伪装成空曲线。
    static func reduction(of points: [SIMD2<Float>], budget: inout GeometryBudget) throws -> StrokeCubicReduction {
        try budget.consume(64)
        guard points.count == 4 else { throw PAGError.invalidArgument("strokeCubicPoints") }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw PAGError.resourceLimitExceeded("geometryPrecision")
        }
        let ab = points[1] - points[0], bc = points[2] - points[1], cd = points[3] - points[2]
        guard ab.x.isFinite, ab.y.isFinite, bc.x.isFinite, bc.y.isFinite, cd.x.isFinite, cd.y.isFinite else {
            throw PAGError.resourceLimitExceeded("geometryPrecision")
        }
        let first = degenerate(ab), second = degenerate(bc), third = degenerate(cd)
        if first && second && third { return .point }
        if (first ? 1 : 0) + (second ? 1 : 0) + (third ? 1 : 0) == 2 { return .line }
        guard try isNearlyLinear(points) else { return .curve(startTangent: first ? points[2] : points[1]) }
        let roots = try curvatureParameters(points, budget: &budget)
        try budget.reserve(3, stride: 16)
        var reduced: [SIMD2<Float>] = []
        for value in roots {
            try budget.consume()
            // 三次解会钳到端点，端点根和求值恰等于首/末点的内部根都必须丢掉。
            guard value > 0, value < 1 else { continue }
            let point = try position(points, at: value)
            if point != points[0], point != points[3] { reduced.append(point) }
        }
        return reduced.isEmpty ? .line : .polyline(reduced)
    }

    /// 已验证四点的F′·F″根，供近共线分类与cusp共享同一Float系数/求根规则。
    static func curvatureParameters(_ points: [SIMD2<Float>], budget: inout GeometryBudget) throws -> [Float] {
        let x = coefficients(points[0].x, points[1].x, points[2].x, points[3].x)
        let y = coefficients(points[0].y, points[1].y, points[2].y, points[3].y)
        return try StrokeCubicPolynomial.roots(x + y, budget: &budget)
    }

    /// 源SkCubicCoeff Horner次序；调用方须已校验四点及有限t，非有限结果抛geometryPrecision。
    static func position(_ points: [SIMD2<Float>], at t: Float) throws -> SIMD2<Float> {
        let a = points[3] + 3 * (points[1] - points[2]) - points[0]
        let b = 3 * (points[2] - 2 * points[1] + points[0])
        let c = 3 * (points[1] - points[0])
        let point = ((a * t + b) * t + c) * t + points[0]
        guard point.x.isFinite, point.y.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        return point
    }

    /// CanNormalize只排除非有限和严格零向量，不使用短边的1/16384门槛。
    private static func degenerate(_ vector: SIMD2<Float>) -> Bool {
        !vector.x.isFinite || !vector.y.isFinite || vector == .zero
    }

    /// 选择首个最大L∞点对，保持源码相等距离时不替换的顺序；其余两点按尺度slop判断。
    private static func isNearlyLinear(_ points: [SIMD2<Float>]) throws -> Bool {
        var maximum: Float = -1
        var first = 0, last = 1
        for index in 0..<3 {
            for other in (index + 1)..<4 {
                let delta = points[other] - points[index], span = max(abs(delta.x), abs(delta.y))
                if maximum < span { maximum = span; first = index; last = other }
            }
        }
        let slop = maximum * maximum * Float(0.00001)
        guard slop.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        let middle = (1 + (2 >> last)) >> first
        let other = first ^ last ^ middle
        return try distanceSquared(points[middle], from: points[first], to: points[last]) <= slop
            && distanceSquared(points[other], from: points[first], to: points[last]) <= slop
    }

    /// 投影在段外时按源码返回到lineStart的距离，不替换为最近端点距离。
    private static func distanceSquared(_ point: SIMD2<Float>, from start: SIMD2<Float>, to end: SIMD2<Float>) throws -> Float {
        let delta = end - start, vector = point - start
        let t = (delta.x * vector.x + delta.y * vector.y) / (delta.x * delta.x + delta.y * delta.y)
        let difference = t >= 0 && t <= 1 ? start * (1 - t) + end * t - point : point - start
        let squared = difference.x * difference.x + difference.y * difference.y
        guard t.isFinite, squared.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        return squared
    }

    /// 单轴F′·F″系数，先各轴完成Float乘加再相加，不能改为Double点积展开。
    private static func coefficients(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float) -> SIMD4<Float> {
        let a = p1 - p0, b = p2 - 2 * p1 + p0, c = p3 + 3 * (p1 - p2) - p0
        return SIMD4(c * c, 3 * b * c, 2 * b * b + c * a, a * b)
    }
}
