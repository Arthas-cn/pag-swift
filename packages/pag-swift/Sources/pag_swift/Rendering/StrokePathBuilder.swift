/// 单次后台中心线准备的预算与规范化路径；保留开放/闭合及零长段，不隐式执行fill过滤。
struct StrokePathBuilder {
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

    /// 追加一条独立源路径；初始Line补原点，close后Line补最近Move，不连接上一条路径。
    mutating func append(_ path: SourcePath, matrix: StrokeFloatTransform, inverse: StrokeFloatTransform?) throws {
        var start = ScenePoint.zero
        var open = false
        var hasMove = false
        var index = 0
        for verb in path.verbs {
            try budget.consume()
            if verb == .line || verb == .cubic {
                if !open {
                    try append(.move, points: [mapped(start, matrix: matrix, inverse: inverse)])
                    open = true
                    hasMove = true
                }
            }
            switch verb {
            case .move:
                start = path.points[index]
                try append(.move, points: [mapped(start, matrix: matrix, inverse: inverse)])
                open = true
                hasMove = true
            case .line:
                try append(.line, points: [mapped(path.points[index], matrix: matrix, inverse: inverse)])
            case .cubic:
                try append(.cubic, points: [mapped(path.points[index], matrix: matrix, inverse: inverse),
                    mapped(path.points[index + 1], matrix: matrix, inverse: inverse),
                    mapped(path.points[index + 2], matrix: matrix, inverse: inverse)])
            case .close:
                // 空Close和连续Close不新增轮廓；Move+Close必须保留，后续Stroke可能产生端点。
                if hasMove && open { try append(.close) }
                open = false
            }
            index += verb.pointCount
        }
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

    /// 顺序执行组坐标与可选逆paint变换；两次Float舍入不可约为一个Double乘积。
    func mapped(_ point: ScenePoint, matrix: StrokeFloatTransform, inverse: StrokeFloatTransform?) throws -> ScenePoint {
        let layer = try matrix.applying(to: point)
        return try inverse?.applying(to: layer) ?? layer
    }
}
