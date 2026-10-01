/// 单次后台中心线准备的预算与规范化路径；保留开放/闭合及零长段，不隐式执行fill过滤。
struct StrokePathBuilder: CurvePathSink {
    /// 中心线存储、模型发布及后续网格准备共享的单次工作/字节预算。
    var budget: GeometryBudget
    /// 描边中心线接纳上限，在实际数组增长前执行。
    let limits: StrokeBackendLimits
    /// 当前累计规范化指令；首条可绘制指令之前总有Move。
    private(set) var verbs: [StrokePathVerb] = []
    /// 指令引用的stroke坐标点，包括所有重复点和曲线控制点。
    private(set) var points: [ScenePoint] = []
    /// 已累计的Move数量，独立SourcePath之间不焊接轮廓。
    private var subpathCount = 0

    /// 增长前校验复杂度、数值与预算，保持非有限/超限失败原子传播。
    mutating func append(_ verb: StrokePathVerb, points newPoints: [ScenePoint] = []) throws {
        try budget.consume()
        guard newPoints.count == verb.pointCount else { throw PAGError.invalidArgument("strokePathPoints") }
        guard verbs.count < limits.maximumInputVerbs else { throw PAGError.resourceLimitExceeded("maximumStrokeInputVerbs") }
        guard newPoints.count <= limits.maximumInputPoints - points.count else {
            throw PAGError.resourceLimitExceeded("maximumStrokeInputPoints")
        }
        if verb == .move {
            guard subpathCount < limits.maximumSubpaths else { throw PAGError.resourceLimitExceeded("maximumStrokeSubpaths") }
            subpathCount += 1
        }
        for point in newPoints { try limits.check(point) }
        try budget.reserve(stride: 16)
        try budget.reserve(newPoints.count, stride: 32)
        verbs.append(verb)
        points.append(contentsOf: newPoints)
    }

    /// 应用完整累计路径恰为零Line时的dash特判；不逐子路径扰动，也不强行保证Float推进。
    mutating func prepareZeroLineForDashing() throws {
        try budget.consume()
        guard verbs == [.move, .line], points.count == 2, points[0] == points[1] else { return }
        let x = try StrokeEvaluation.finite(points[1].x)
        let adjusted = x + max(Float(1.001), x) * Float(1.0 / 4096)
        let point = ScenePoint(x: Double(adjusted), y: points[1].y)
        try limits.check(point)
        points[1] = point
    }

    /// 完整验证后发布保留曲线类型的中心线；模型保活与临时builder分别计费。
    mutating func finish() throws -> StrokePath {
        try StrokePath(verbs: verbs, points: points, budget: &budget)
    }


}
