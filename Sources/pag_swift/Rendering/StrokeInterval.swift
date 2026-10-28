/// Conic适配器内部的有限闭区间；只提供误差包围所需运算，不是公开数值库。
struct StrokeInterval {
    /// 精确结果的有限下界，允许负值。
    let lower: Double
    /// 精确结果的有限上界，不小于lower。
    let upper: Double

    /// 精确零，在乘零或相同精确值相减时避免无意义扩张。
    static let zero = StrokeInterval(lower: 0, upper: 0)

    /// 将已经存储的Double视为精确输入；非有限值无法参与几何证明。
    init(_ value: Double) throws {
        guard value.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        lower = value
        upper = value
    }

    /// 仅接收本类型已检查的边界，不对外开放未经验证的区间。
    private init(lower: Double, upper: Double) {
        self.lower = lower
        self.upper = upper
    }

    /// 生成候选控制点的代表值；它不是误差界，最终候选仍必须反代验证。
    var midpoint: Double { lower == upper ? lower : lower * 0.5 + upper * 0.5 }

    /// 区间内任意值的绝对值上界，无需近似平方或开根。
    var maximumMagnitude: Double { max(abs(lower), abs(upper)) }

    /// 是否恰为单点零，用于保持精确零乘法。
    private var isZero: Bool { lower == 0 && upper == 0 }

    /// 相加并对两个端点向外舍入；无法保留有限包围时报精度资源错误。
    func adding(_ other: Self) throws -> Self {
        if isZero { return other }
        if other.isZero { return self }
        return try Self.outward(lower + other.lower, upper + other.upper)
    }

    /// 相减时使用交叉端点，只有两个精确相同单点才能直接消去。
    func subtracting(_ other: Self) throws -> Self {
        if other.isZero { return self }
        if lower == upper, other.lower == other.upper, lower == other.lower { return .zero }
        return try Self.outward(lower - other.upper, upper - other.lower)
    }

    /// 四个端点积包围任意符号的乘法，任何溢出都不变成无限宽的成功区间。
    func multiplying(_ other: Self) throws -> Self {
        if isZero || other.isZero { return .zero }
        return try Self.enclosing(lower * other.lower, lower * other.upper,
                                  upper * other.lower, upper * other.upper)
    }

    /// 除数必须具有严格正下界；四个端点商避免先取倒数时增加不必要扩张。
    func divided(by other: Self) throws -> Self {
        guard other.lower > 0 else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        if isZero { return .zero }
        return try Self.enclosing(lower / other.lower, lower / other.upper,
                                  upper / other.lower, upper / other.upper)
    }

    /// 与一个实际Double系数相乘，系数本身也必须有限。
    func scaled(by value: Double) throws -> Self { try multiplying(Self(value)) }

    /// 齐次二分中的平均值；先除二再相加，避免同号大值的无谓溢出。
    func averaged(with other: Self) throws -> Self {
        try scaled(by: 0.5).adding(other.scaled(by: 0.5))
    }

    /// 包围四个有限候选极值；这是乘除端点的共同校验，不允许NaN污染min/max。
    private static func enclosing(_ a: Double, _ b: Double, _ c: Double, _ d: Double) throws -> Self {
        guard a.isFinite, b.isFinite, c.isFinite, d.isFinite else {
            throw PAGError.resourceLimitExceeded("geometryPrecision")
        }
        return try outward(min(a, b, c, d), max(a, b, c, d))
    }

    /// 基本Double运算后各扩一个相邻数，覆盖舍入误差；无有限邻数时明确失败。
    private static func outward(_ lower: Double, _ upper: Double) throws -> Self {
        let lower = lower.nextDown, upper = upper.nextUp
        guard lower.isFinite, upper.isFinite, lower <= upper else {
            throw PAGError.resourceLimitExceeded("geometryPrecision")
        }
        return Self(lower: lower, upper: upper)
    }
}
