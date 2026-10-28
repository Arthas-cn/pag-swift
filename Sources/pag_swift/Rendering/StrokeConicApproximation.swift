/// 把正权重conic变为有位置误差包围的三次段；不负责dash弧长、描边偏移或平台路径。
enum StrokeConicApproximation {
    /// 按复原矩阵后的层坐标容差生成完整近似；非法输入、精度/预算耗尽或取消均不返回半份数组。
    static func cubics(_ conic: StrokeConic, tolerance: Double, transform: SceneAffine,
                       budget: inout GeometryBudget) throws -> [StrokeCubic] {
        try Task.checkCancellation()
        guard tolerance.isFinite, tolerance > 0 else { throw PAGError.invalidArgument("geometryTolerance") }
        guard conic.points.count == 3, conic.weights.count == 3,
              conic.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              conic.weights.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw PAGError.invalidArgument("strokeConic")
        }
        try budget.reserve(stride: 1024)
        let origin = conic.points[0]
        let controls = try zip(conic.points, conic.weights).map {
            try StrokeHomogeneousPoint(point: $0, weight: $1, origin: origin)
        }
        var stack = [ConicWork(controls: controls, start: conic.points[0], end: conic.points[2],
                              lower: 0, upper: 1, depth: 0)]
        var result: [StrokeCubic] = []
        while let item = stack.popLast() {
            // 每项有固定六组Bernstein系数验证；先计入工作，不能只给输出点计费。
            try budget.consume(128)
            let candidate = try item.candidate()
            if try errorBound(item.controls, candidate: candidate, origin: origin, transform: transform) <= tolerance {
                try budget.reserve(stride: 128)
                result.append(candidate)
                continue
            }
            guard item.depth < budget.maximumDepth else {
                throw PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")
            }
            try budget.reserve(2, stride: 1024)
            let halves = try item.split(origin: origin)
            // 先压右段；中点只生成一次，左右使用同一实际Double点，避免近似接缝。
            stack.append(halves.1)
            stack.append(halves.0)
        }
        try Task.checkCancellation()
        return result
    }

    /// 五次Bernstein残差的凸包界；区间覆盖原曲线、候选存储和系数/变换运算的舍入。
    private static func errorBound(_ controls: [StrokeHomogeneousPoint], candidate: StrokeCubic,
                                   origin: ScenePoint, transform: SceneAffine) throws -> Double {
        let points = [candidate.start, candidate.first, candidate.second, candidate.end]
        let minimumWeight = try StrokeInterval(controls.map { $0.weight.lower }.min() ?? 0)
        // N升到五次与D乘三次共享同一乘积系数，直接累加N_i-D_i*C_j减少消减。
        let quadratic = [1.0, 2, 1], cubic = [1.0, 3, 3, 1], fifth = [1.0, 5, 10, 10, 5, 1]
        var bound = 0.0
        for degree in 0...5 {
            var x = StrokeInterval.zero, y = StrokeInterval.zero
            for i in 0...2 {
                let j = degree - i
                guard (0...3).contains(j) else { continue }
                let coefficient = try StrokeInterval(quadratic[i] * cubic[j]).divided(by: StrokeInterval(fifth[degree]))
                let localX = try StrokeInterval(points[j].x).subtracting(StrokeInterval(origin.x))
                let localY = try StrokeInterval(points[j].y).subtracting(StrokeInterval(origin.y))
                let partX = try controls[i].x.subtracting(controls[i].weight.multiplying(localX))
                let partY = try controls[i].y.subtracting(controls[i].weight.multiplying(localY))
                x = try x.adding(partX.multiplying(coefficient))
                y = try y.adding(partY.multiplying(coefficient))
            }
            let mappedX = try x.scaled(by: transform.a).adding(y.scaled(by: transform.c))
            let mappedY = try x.scaled(by: transform.b).adding(y.scaled(by: transform.d))
            // L1包围欧氏长度；相加和除最小正权重也向外舍入，不依赖近似sqrt的方向。
            let magnitude = try StrokeInterval(mappedX.maximumMagnitude).adding(StrokeInterval(mappedY.maximumMagnitude))
            bound = max(bound, try magnitude.divided(by: minimumWeight).upper)
        }
        return bound
    }
}

/// 一项保留原参数范围和齐次包围的待细分工作；无平台对象或共享游标。
private struct ConicWork {
    /// 原始曲线在该参数区间的三个齐次控制点包围。
    let controls: [StrokeHomogeneousPoint]
    /// 当前实际输出起点，根端点或父项产生的共享中点。
    let start: ScenePoint
    /// 当前实际输出终点，与相邻段复用同一值。
    let end: ScenePoint
    /// 原始参数区间的下界，二进制细分时可精确表示。
    let lower: Double
    /// 原始参数区间的上界，大于lower。
    let upper: Double
    /// 已完成的二分次数，由GeometryBudget限定。
    let depth: Int

    /// 生成端点Hermite候选；普通Double只决定候选，能否接受由原齐次残差验证。
    func candidate() throws -> StrokeCubic {
        let firstPoint = try controls[0].representative()
        let middlePoint = try controls[1].representative()
        let lastPoint = try controls[2].representative()
        let firstRatio = (controls[1].weight.midpoint / controls[0].weight.midpoint) * (2.0 / 3)
        let lastRatio = (controls[1].weight.midpoint / controls[2].weight.midpoint) * (2.0 / 3)
        let first = try checked(ScenePoint(x: start.x + firstRatio * (middlePoint.x - firstPoint.x),
                                          y: start.y + firstRatio * (middlePoint.y - firstPoint.y)))
        let second = try checked(ScenePoint(x: end.x + lastRatio * (middlePoint.x - lastPoint.x),
                                           y: end.y + lastRatio * (middlePoint.y - lastPoint.y)))
        return StrokeCubic(start: start, first: first, second: second, end: end,
                           startParameter: lower, endParameter: upper)
    }

    /// 齐次二分保持原参数映射；中点的实际存储误差在左右候选的残差中再次验证。
    func split(origin: ScenePoint) throws -> (Self, Self) {
        let first = try controls[0].averaged(with: controls[1])
        let second = try controls[1].averaged(with: controls[2])
        let middle = try first.averaged(with: second)
        let point = try middle.representative()
        let endpoint = try checked(ScenePoint(x: origin.x + point.x, y: origin.y + point.y))
        let parameter = lower * 0.5 + upper * 0.5
        guard parameter > lower, parameter < upper else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        return (Self(controls: [controls[0], first, middle], start: start, end: endpoint,
                     lower: lower, upper: parameter, depth: depth + 1),
                Self(controls: [middle, second, controls[2]], start: endpoint, end: end,
                     lower: parameter, upper: upper, depth: depth + 1))
    }

    /// 有限输入可能在候选计算中溢出，此时失败而不是发布不可验证控制点。
    private func checked(_ point: ScenePoint) throws -> ScenePoint {
        guard point.x.isFinite, point.y.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        return point
    }
}
