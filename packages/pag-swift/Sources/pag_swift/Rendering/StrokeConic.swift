/// 描边后台适配中的正权重rational quadratic；不改变PAG字节路径模型。
struct StrokeConic: Sendable {
    /// 三个有限欧氏控制点，转换入口验证数量；首末点属于原曲线。
    let points: [ScenePoint]
    /// 与控制点一一对应的三个正有限齐次权重；源圆角为1、Float根二除二、1。
    let weights: [Double]
}

/// Conic的一段实际Double三次近似；参数范围供连续性与独立数值验证使用。
struct StrokeCubic: Sendable {
    /// 当前子段的起点，与前段终点逐位共享。
    let start: ScenePoint
    /// Hermite候选的第一个三次控制点，最终值已接受区间残差验证。
    let first: ScenePoint
    /// 第二个三次控制点，保留结束处的一侧切向。
    let second: ScenePoint
    /// 当前子段终点；原曲线最后一段复用原始终点。
    let end: ScenePoint
    /// 本段对应原始rational曲线的起参数，范围0..<1。
    let startParameter: Double
    /// 本段对应原曲线的终参数，严格大于起参数且不超过1。
    let endParameter: Double
}

/// 包围原始曲线某个齐次控制点的区间；二分时不能只保留已舍入的欧氏点。
struct StrokeHomogeneousPoint {
    /// 相对根首点的水平齐次分子区间。
    let x: StrokeInterval
    /// 相对根首点的垂直齐次分子区间。
    let y: StrokeInterval
    /// 齐次分母系数区间，必须保留严格正下界。
    let weight: StrokeInterval

    /// 对实际输入做平移抵消后进入齐次区间，避免绝对坐标吞没残差。
    init(point: ScenePoint, weight: Double, origin: ScenePoint) throws {
        let weight = try StrokeInterval(weight)
        x = try StrokeInterval(point.x).subtracting(StrokeInterval(origin.x)).multiplying(weight)
        y = try StrokeInterval(point.y).subtracting(StrokeInterval(origin.y)).multiplying(weight)
        self.weight = weight
    }

    /// 保存已经包围的齐次值，供二分内部使用。
    private init(x: StrokeInterval, y: StrokeInterval, weight: StrokeInterval) {
        self.x = x
        self.y = y
        self.weight = weight
    }

    /// 齐次de Casteljau平均；全部分量保持区间，分母失去正下界时停止。
    func averaged(with other: Self) throws -> Self {
        let weight = try weight.averaged(with: other.weight)
        guard weight.lower > 0 else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        return try Self(x: x.averaged(with: other.x), y: y.averaged(with: other.y), weight: weight)
    }

    /// 反投影区间的代表点，只供生成候选；误差界始终保留原齐次区间。
    func representative() throws -> ScenePoint {
        try ScenePoint(x: x.divided(by: weight).midpoint, y: y.divided(by: weight).midpoint)
    }
}
