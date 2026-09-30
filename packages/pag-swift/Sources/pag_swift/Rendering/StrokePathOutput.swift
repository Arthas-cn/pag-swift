/// 最终SourcePath矢量输出的局部状态，供描边边界和hairline出口使用，不跨任务或暂停点。
final class StrokePathOutput {
    /// 临时几何、输出增长和最后复原共同扣减的单次预算。
    var budget: GeometryBudget
    /// 单次stroke的本库输出数量和stroke坐标幅度策略。
    let limits: StrokeBackendLimits
    /// 已完整校验的路径指令；失败时整体丢弃。
    private var verbs: [SourcePathVerb] = []
    /// 已存储的实际Double坐标，不降成Float。
    private var points: [ScenePoint] = []
    /// 最新终点，nil表示尚无Move，供零Line生成和指令序列检查。
    private var current: ScenePoint?
    /// 最新Move起点，Close将游标恢复到这里。
    private var start: ScenePoint?

    /// 先向调用方计费再保存预算；初始化中途失败也保留已消费工作量，不能等外层defer回传。
    init(budget: inout GeometryBudget, limits: StrokeBackendLimits) throws {
        try budget.consume()
        try budget.reserve(stride: 128)
        self.budget = budget
        self.limits = limits
    }

    /// 校验纯值后端生成的单个指令，在数组增长前检查element上限、幅度和预算。
    func append(_ verb: SourcePathVerb, points values: [ScenePoint] = []) throws {
        try budget.consume()
        guard values.count == verb.pointCount else { throw PAGError.invalidArgument("strokeOutputPoints") }
        guard verbs.count < limits.maximumOutputElements else {
            throw PAGError.resourceLimitExceeded("maximumStrokeOutputElements")
        }
        guard verb == .move || current != nil else { throw PAGError.renderingFailure("strokePathSequence") }
        for value in values {
            guard value.x.isFinite, value.y.isFinite else { throw PAGError.renderingFailure("strokeNonFinite") }
            try limits.check(value)
        }
        try budget.reserve(stride: 8)
        try budget.reserve(values.count, stride: 32)
        verbs.append(verb)
        points.append(contentsOf: values)
        if verb == .move { start = values[0] }
        current = verb == .close ? start : values.last
    }

    /// 零on虚线必须复制当前输出终点形成真实零Line；缺少Move表示内部调用次序错误。
    func appendZeroLengthLine() throws {
        guard let current else { throw PAGError.renderingFailure("strokePathSequence") }
        try append(.line, points: [current])
    }

    /// 完整成功后以Double复原paint矩阵并发布SourcePath；不返回部分复原的路径。
    func finish(restoring matrix: SceneAffine = .identity) throws -> SourcePath {
        for index in points.indices {
            try budget.consume()
            points[index] = try matrix.applying(to: points[index])
        }
        try budget.reserve(stride: 128)
        return try SourcePath(verbs: verbs, points: points)
    }

}
