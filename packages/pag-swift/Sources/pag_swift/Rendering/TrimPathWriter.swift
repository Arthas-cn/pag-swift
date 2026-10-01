/// 单次Trim转换、反转或提取的局部曲线存储，只按共享几何预算增长，不执行Stroke专项接纳。
struct TrimPathWriter: CurvePathSink {
    /// 与整个裁剪批次共用的预算，调用方以defer收回成功或失败已消耗的成本。
    var budget: GeometryBudget
    /// 尚未发布的指令序列；最终由StrokePath验证规范化结构。
    private(set) var verbs: [StrokePathVerb] = []
    /// 保留全部控制点、重复点与Move，不把零长度段当成无效填充删掉。
    private(set) var points: [ScenePoint] = []
    /// 当前端点，空路径为nil；Close后回到最近的Move起点。
    private(set) var current: ScenePoint?
    /// 最近Move的起点，供Close恢复位置；尚无Move时为nil。
    private var start: ScenePoint?

    /// 接收调用者已有预算，不创建新的逐路径配额或共享可变状态。
    init(budget: GeometryBudget) { self.budget = budget }

    /// 验证单条指令的点数与有限性并预付成本；结构次序由finish统一检查。
    mutating func append(_ verb: StrokePathVerb, points newPoints: [ScenePoint]) throws {
        try budget.consume(1 + newPoints.count)
        guard newPoints.count == verb.pointCount else { throw PAGError.invalidArgument("strokePathPoints") }
        for point in newPoints {
            guard point.x.isFinite, point.y.isFinite else { throw PAGError.renderingFailure("trimPrecision") }
        }
        try budget.reserve(stride: 16)
        try budget.reserve(newPoints.count, stride: 32)
        verbs.append(verb)
        points.append(contentsOf: newPoints)
        if verb == .move { start = newPoints[0] }
        current = verb == .close ? start : newPoints.last
    }

    /// 保留源segTo对相等参数的零Line；即使位置重复也不能删掉后续cap/dash所需拓扑。
    mutating func appendZeroLengthLine() throws {
        guard let current else { throw PAGError.invalidArgument("missingTrimCurrentPoint") }
        try append(.line, points: [current])
    }

    /// 发布完整、不可变、保留曲线类型的路径；布局或预算错误不返回部分结果。
    mutating func finish() throws -> StrokePath {
        try StrokePath(verbs: verbs, points: points, budget: &budget)
    }
}
