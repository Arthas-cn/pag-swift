/// PolyStar单帧的纯值描述；比较完整参数以复用颜色/alpha帧的网格，不逐帧展开顶点。
struct PolyStarContour: Sendable, Equatable {
    /// 星形或多边形的源生成方式。
    let kind: SourcePolyStarKind
    /// 源角度步进方向，不能用路径数组倒序替代。
    let reversed: Bool
    /// 保留小数的源点数，Int32可表示性在实际路径生成前检查。
    let points: Float
    /// 已往返源Float的中心坐标，尚未应用组矩阵。
    let position: ScenePoint
    /// 原始角度，未减90或换算弧度。
    let rotation: Float
    /// 源内半径，Polygon也保留并参与缓存身份。
    let innerRadius: Float
    /// 源外半径，负值不取绝对值。
    let outerRadius: Float
    /// 内顶点的原始圆度比例，不夹到单位区间。
    let innerRoundness: Float
    /// 外顶点的原始圆度比例，零表示无圆度。
    let outerRoundness: Float
    /// 局部路径到图层的完整组矩阵。
    let matrix: SceneAffine

    /// 在同一源帧完整求值七条轨道；Polygon也不跳过内属性，有限Float之外或取消明确失败。
    static func make(_ source: SourcePolyStar, at frame: Int64, matrix: SceneAffine) throws -> Self {
        try Task.checkCancellation()
        let points = try finite(PropertyEvaluation.scalar(source.points, at: frame))
        let position = try PropertyEvaluation.point(source.position, at: frame)
        let x = try finite(position.x), y = try finite(position.y)
        let rotation = try finite(PropertyEvaluation.scalar(source.rotation, at: frame))
        let innerRadius = try finite(PropertyEvaluation.scalar(source.innerRadius, at: frame))
        let outerRadius = try finite(PropertyEvaluation.scalar(source.outerRadius, at: frame))
        let innerRoundness = try finite(PropertyEvaluation.scalar(source.innerRoundness, at: frame))
        let outerRoundness = try finite(PropertyEvaluation.scalar(source.outerRoundness, at: frame))
        return Self(kind: source.kind, reversed: source.reversed, points: points,
            position: ScenePoint(x: Double(x), y: Double(y)), rotation: rotation,
            innerRadius: innerRadius, outerRadius: outerRadius, innerRoundness: innerRoundness,
            outerRoundness: outerRoundness, matrix: matrix)
    }

    /// Float是上游路径生成的实际计算域，不能保留仅Double可表示的属性继续计算。
    private static func finite(_ value: Double) throws -> Float {
        let result = Float(value)
        guard result.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        return result
    }
}
