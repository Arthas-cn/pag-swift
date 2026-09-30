import Foundation

/// 扫描器的规范非水平边；保留源绕序，并用局部区间证书处理交点高度量化。
struct ScanBoundary {
    /// 较小y的源端点，不由输入绕序决定。
    let lower: ScenePoint
    /// 较大y的源端点，必须严格高于lower.y。
    let upper: ScenePoint
    /// 源边向大y时为1，反向为−1，不使用会回绕的8位计数。
    let winding: Int

    /// 规范化已经验证的非水平边，方向单独保留用于nonzero累计。
    init(_ first: ScenePoint, _ second: ScenePoint) {
        let forward = first.y < second.y
        lower = forward ? first : second
        upper = forward ? second : first
        winding = forward ? 1 : -1
    }

    /// 在闭区间内插值；源端点直接返回，普通热路径不执行区间运算。
    func x(at y: Double) -> Double {
        if y == lower.y { return lower.x }
        if y == upper.y { return upper.x }
        let fraction = (y - lower.y) / (upper.y - lower.y)
        return lower.x.addingProduct(fraction, upper.x - lower.x)
    }

    /// 返回有序边界；反序只能在相邻高度证明有真实交点后折叠，否则整次几何准备失败。
    static func ordered(_ left: ScanBoundary, _ right: ScanBoundary, at y: Double,
                        budget: inout GeometryBudget) throws -> (Double, Double) {
        let a = left.x(at: y), b = right.x(at: y)
        guard a.isFinite, b.isFinite else { throw PAGError.renderingFailure("geometryNonFinite") }
        if a <= b { return (a, b) }
        // 区间求值自身不分配数组；符号不确定时的精确展开会另行计费临时存储。
        try budget.consume(64)
        let lowY = max(y.nextDown, left.lower.y, right.lower.y)
        let highY = min(y.nextUp, left.upper.y, right.upper.y)
        guard lowY < highY else { throw PAGError.renderingFailure("geometryOrdering") }
        let a0 = try left.bounds(at: lowY), a1 = try left.bounds(at: highY)
        let b0 = try right.bounds(at: lowY), b1 = try right.bounds(at: highY)
        // 必须在相同y比较两条边。各自整段x范围重叠无法排除同向陡边的假交叉。
        let lowSign = try sign(a0, b0, left: left, right: right, at: lowY, budget: &budget)
        let highSign = try sign(a1, b1, left: left, right: right, at: highY, budget: &budget)
        guard lowSign * highSign == -1 else {
            throw PAGError.renderingFailure("geometryOrdering")
        }
        let lowX = max(min(a0.lower, a1.lower), min(b0.lower, b1.lower))
        let highX = min(max(a0.upper, a1.upper), max(b0.upper, b1.upper))
        let leftSlope = abs(left.upper.x - left.lower.x) / (left.upper.y - left.lower.y)
        let rightSlope = abs(right.upper.x - right.lower.x) / (right.upper.y - right.lower.y)
        guard lowX <= highX, leftSlope.isFinite, rightSlope.isFinite else {
            throw PAGError.renderingFailure("geometryOrdering")
        }
        // 平缓边减少y量化放大；夹到共同包围内，不能仅凭一条边的估值移动两边端点。
        let shared = min(highX, max(lowX, leftSlope <= rightSlope ? a : b))
        return (shared, shared)
    }

    /// 证明共同定义域内同高度的插值差符号；区间和精确回退均计费，取消立即传播。
    static func difference(_ left: ScanBoundary, _ right: ScanBoundary, at y: Double,
                           budget: inout GeometryBudget) throws -> Int {
        try budget.consume(32)
        return try sign(left.bounds(at: y), right.bounds(at: y), left: left, right: right, at: y, budget: &budget)
    }

    /// 优先用区间证明严格符号；区间重叠仅表示未知，必须用精确展开继续核算。
    private static func sign(_ a: ScanInterval, _ b: ScanInterval, left: ScanBoundary,
                             right: ScanBoundary, at y: Double, budget: inout GeometryBudget) throws -> Int {
        if a.upper < b.lower { return -1 }
        if a.lower > b.upper { return 1 }
        return try ScanExactSign.difference(left, right, at: y, budget: &budget)
    }

    /// 包围给定高度的精确实数插值；靠近哪个端点就从哪个端点计算，减少消去误差。
    private func bounds(at y: Double) throws -> ScanInterval {
        if y == lower.y || lower.x == upper.x { return ScanInterval(lower.x) }
        if y == upper.y { return ScanInterval(upper.x) }
        let anchor = y - lower.y <= upper.y - y ? lower : upper
        let numerator = try ScanInterval.difference(y, anchor.y)
        let denominator = try ScanInterval.difference(upper.y, lower.y)
        let fraction = try numerator.divided(by: denominator)
        let delta = try ScanInterval.difference(upper.x, lower.x)
        return try fraction.multiplied(by: delta, adding: anchor.x)
    }
}

/// 仅供扫描边界冷分支使用的有限闭区间；每步向外舍入，不把重叠当作相等证明。
private struct ScanInterval {
    /// 精确实数结果的有限下包围。
    let lower: Double
    /// 精确实数结果的有限上包围，不小于lower。
    let upper: Double

    /// 源Double被视为精确输入，无运算时无需人为扩大区间。
    init(_ value: Double) { lower = value; upper = value }

    /// 检查向外舍入结果；溢出或非法顺序必须失败，不能拿无穷区间接纳任意交点。
    private init(lower: Double, upper: Double) throws {
        guard lower.isFinite, upper.isFinite, lower <= upper else {
            throw PAGError.renderingFailure("geometryNonFinite")
        }
        self.lower = lower
        self.upper = upper
    }

    /// 两个精确输入相减的包围；相同输入精确为零，保留此已知关系。
    static func difference(_ first: Double, _ second: Double) throws -> ScanInterval {
        if first == second { return ScanInterval(0) }
        let value = first - second
        return try ScanInterval(lower: value.nextDown, upper: value.nextUp)
    }

    /// 正分母区间除法，四个端值包围结果；无法证明正分母时保守拒绝。
    func divided(by divisor: ScanInterval) throws -> ScanInterval {
        guard divisor.lower > 0 else { throw PAGError.renderingFailure("geometryOrdering") }
        let a = lower / divisor.lower, b = lower / divisor.upper
        let c = upper / divisor.lower, d = upper / divisor.upper
        return try ScanInterval(lower: min(a, b, c, d).nextDown, upper: max(a, b, c, d).nextUp)
    }

    /// 双线性乘法的极值在四角；FMA将加锚点合为一次舍入，再向外取相邻值。
    func multiplied(by other: ScanInterval, adding anchor: Double) throws -> ScanInterval {
        let a = anchor.addingProduct(lower, other.lower), b = anchor.addingProduct(lower, other.upper)
        let c = anchor.addingProduct(upper, other.lower), d = anchor.addingProduct(upper, other.upper)
        return try ScanInterval(lower: min(a, b, c, d).nextDown, upper: max(a, b, c, d).nextUp)
    }
}
