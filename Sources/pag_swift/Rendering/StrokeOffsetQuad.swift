/// 源射线相交的三种结果；Degenerate是否可成直线还取决于共享状态与反向切线。
enum StrokeRayIntersection: Equatable {
    /// 交点可表示，仍须通过曲线位置与尖角判据才能输出二次段。
    case quadratic
    /// 平行、比例失效或外侧交点足够靠近端点，调用方决定能否接受直线。
    case degenerate
    /// 当前区间不能由单二次段表示，须继续二分。
    case split
}

/// 单个全局t区间的候选二次偏移；递归子节点只继承父节点对应外端ray。
struct StrokeOffsetQuad {
    /// 原曲线上的区间起点，允许子区间发生Float中点停滞。
    let start: Float
    /// 原曲线上的区间终点，未重参数化。
    let end: Float
    /// 区间起点偏移与切线，继承时保留同一Float值。
    let first: StrokeOffsetRay
    /// 区间终点偏移与切线，继承时保留同一Float值。
    let last: StrokeOffsetRay
    /// 仅求交请求控制点且返回quadratic后有效；结果模式不写入它。
    private(set) var control = SIMD2<Float>.zero
    /// 最近一次退化求交是否切线反向；非退化求交始终重置为false。
    private(set) var oppositeTangents = false
    /// 源Float加法后乘半，不使用Double或防溢出的另一种中点公式。
    var middle: Float { (start + end) * 0.5 }

    /// 构造已采样的候选；调用方保证参数有序且ray有限，停滞由递归控制器处理。
    init(start: Float, end: Float, first: StrokeOffsetRay, last: StrokeOffsetRay) {
        self.start = start
        self.end = end
        self.first = first
        self.last = last
    }

    /// 按源交点符号及Float比例判据分类；需要控制点时才保存，数值失败不变成成功。
    mutating func intersection(needsControl: Bool, budget: inout GeometryBudget) throws -> StrokeRayIntersection {
        try budget.consume(32)
        let a = first.tangent - first.offset, b = last.tangent - last.offset
        let denominator = StrokeCubicSampling.cross(a, b)
        if denominator == 0 || !denominator.isFinite {
            // 源显式把零/非有限分母当作平行退化；不能用统一finite检查覆盖这个分支。
            oppositeTangents = a.x * b.x + a.y * b.y < 0
            return .degenerate
        }
        oppositeTangents = false
        let delta = first.offset - last.offset
        let numerator = StrokeCubicSampling.cross(b, delta), other = StrokeCubicSampling.cross(a, delta)
        if (numerator >= 0) == (other >= 0) {
            let firstDistance = Self.distanceSquared(first.offset, from: last.offset, to: last.tangent)
            let lastDistance = Self.distanceSquared(last.offset, from: first.offset, to: first.tangent)
            return max(firstDistance, lastDistance) <= 0.0625 ? .degenerate : .split
        }
        let ratio = numerator / denominator
        if ratio > ratio - 1 {
            if needsControl {
                control = first.offset * (1 - ratio) + first.tangent * ratio
                guard control.x.isFinite, control.y.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
            }
            return .quadratic
        }
        oppositeTangents = a.x * b.x + a.y * b.y < 0
        return .degenerate
    }

    /// 候选二次段相对中点ray满足源局部启发式时返回true；不承诺全局位置误差界。
    func accepts(_ ray: StrokeOffsetRay, budget: inout GeometryBudget) throws -> Bool {
        try budget.consume(32)
        if Self.within(ray.offset, position(at: 0.5), limit: 0.25) { return !hasSharpAngle() }
        let minimum = SIMD2(min(first.offset.x, control.x, last.offset.x), min(first.offset.y, control.y, last.offset.y))
        let maximum = SIMD2(max(first.offset.x, control.x, last.offset.x), max(first.offset.y, control.y, last.offset.y))
        if ray.offset.x + 0.25 < minimum.x || ray.offset.x - 0.25 > maximum.x
            || ray.offset.y + 0.25 < minimum.y || ray.offset.y - 0.25 > maximum.y { return false }
        let vector = ray.curve - ray.offset
        let r0 = StrokeCubicSampling.cross(vector, first.offset - ray.offset)
        let r1 = StrokeCubicSampling.cross(vector, control - ray.offset)
        let r2 = StrokeCubicSampling.cross(vector, last.offset - ray.offset)
        let roots = try StrokeCubicPolynomial.quadraticRoots(r2 + (r0 - 2 * r1), 2 * (r1 - r0), r0, budget: &budget)
        guard roots.count == 1 else { return false }
        let error = Float(0.25) * (1 - abs(roots[0] - 0.5) * 2)
        return Self.within(ray.offset, position(at: roots[0]), limit: error) && !hasSharpAngle()
    }

    /// 已初始化control后的源Float quadratic Horner求值，不用权重1的通用有理除法。
    func position(at parameter: Float) -> SIMD2<Float> {
        let a = last.offset - 2 * control + first.offset, b = 2 * (control - first.offset)
        return (a * parameter + b) * parameter + first.offset
    }

    /// 源sharp_angle把较短向量缩放到较长向量的平方长度；true要求拒绝当前二次段。
    private func hasSharpAngle() -> Bool {
        var smaller = control - first.offset, larger = control - last.offset
        let smallLength = StrokeCubicSampling.squared(smaller)
        var largeLength = StrokeCubicSampling.squared(larger)
        if smallLength > largeLength { swap(&smaller, &larger); largeLength = smallLength }
        guard let scaled = StrokeLineMath.scaled(smaller, length: largeLength) else { return false }
        return scaled.x * larger.x + scaled.y * larger.y > 0
    }

    /// 源Float平方距离含等号门槛，供端点近距与quad误差判据共享。
    static func within(_ first: SIMD2<Float>, _ second: SIMD2<Float>, limit: Float) -> Bool {
        StrokeCubicSampling.squared(first - second) <= limit * limit
    }

    /// 源pt_to_line；段外投影和零弦的0/0都取到lineStart的距离，不能改成最近点。
    static func distanceSquared(_ point: SIMD2<Float>, from start: SIMD2<Float>, to end: SIMD2<Float>) -> Float {
        let delta = end - start, vector = point - start
        let t = (delta.x * vector.x + delta.y * vector.y) / StrokeCubicSampling.squared(delta)
        let difference = t >= 0 && t <= 1 ? start * (1 - t) + end * t - point : point - start
        return StrokeCubicSampling.squared(difference)
    }
}
