/// 单次同步虚线提取的临时路径输出器；保留Quad/Conic，不承担最终fill转换或跨任务共享。
final class StrokeDashOutput {
    /// 临时存储与发布模型共同消费的预算；失败后由拥有者回传，已耗成本不退回。
    var budget: GeometryBudget
    /// 实际输出元素和坐标幅度政策；输入配额在完整dash输出后重新接纳。
    let limits: StrokeBackendLimits
    /// 尚未发布的指令；单位Conic权重按同一模型规则规范化为Quad。
    private var verbs: [StrokePathVerb] = []
    /// 保留Double精度的控制点与端点，不在存储时增加Float量化。
    private var points: [ScenePoint] = []
    /// 当前未关闭子路径的末点；nil表示尚无Move或刚完成Close。
    private var current: ScenePoint?

    /// 先向调用方计费再保存预算；初始化失败也不能丢掉已消耗工作。
    init(budget: inout GeometryBudget, limits: StrokeBackendLimits) throws {
        try budget.consume()
        try budget.reserve(stride: 128)
        self.budget = budget
        self.limits = limits
    }

    /// 校验指令、点和权重后预付增长；非法序列、非有限坐标或资源不足使整份候选失败。
    func append(_ verb: StrokePathVerb, points values: [ScenePoint] = []) throws {
        try budget.consume()
        guard values.count == verb.pointCount else { throw PAGError.invalidArgument("strokeOutputPoints") }
        guard verbs.count < limits.maximumOutputElements else {
            throw PAGError.resourceLimitExceeded("maximumStrokeOutputElements")
        }
        guard verb == .move || current != nil else { throw PAGError.renderingFailure("strokePathSequence") }
        let normalized = try verb.normalized()
        for value in values {
            guard value.x.isFinite, value.y.isFinite else { throw PAGError.renderingFailure("strokeNonFinite") }
            try limits.check(value)
        }
        try budget.reserve(stride: 16)
        try budget.reserve(values.count, stride: 32)
        verbs.append(normalized)
        points.append(contentsOf: values)
        // Close后必须显式新Move；保留首点作为current会误放行后续直接绘制和重复Close。
        current = verb == .close ? nil : values.last
    }

    /// 复制当前实际输出点追加零Line；不重新采样，缺少未关闭Move时报序列错误。
    func appendZeroLengthLine() throws {
        guard let current else { throw PAGError.renderingFailure("strokePathSequence") }
        try append(.line, points: [current])
    }

    /// 再次完整验证并计入发布模型存储；失败不返回前缀，也不复原paint矩阵。
    func finish() throws -> StrokePath {
        try StrokePath(verbs: verbs, points: points, budget: &budget)
    }
}
