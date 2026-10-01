/// 一条已完成Trim的图层坐标曲线；身份跨颜色帧保持，不持有可变游标或GPU对象。
final class PreparedTrimPath: Sendable {
    /// 完整规范化曲线，保留原生Conic和开放轮廓供Fill/Stroke分别消费。
    let path: StrokePath
    /// 包括指令、点数组和对象外壳的保守保活字节数。
    let estimatedBytes: Int

    /// 保存已经验证的路径；只计算计费，不再次遍历或复制点列。
    init(_ path: StrokePath) throws {
        var cost = FramePlanBudget(limit: Int.max, resourceName: "maximumTrimBytes")
        try Self.retain(path, budget: &cost)
        self.path = path
        estimatedBytes = cost.used
    }

    /// 统一计算纯曲线的保活成本，整数溢出按资源错误处理。
    static func retain(_ path: StrokePath, budget: inout FramePlanBudget) throws {
        try budget.reserve(stride: 128)
        try budget.reserve(count: path.verbs.count, stride: 16)
        try budget.reserve(count: path.points.count, stride: 32)
    }
}

/// 一条输入在指定方向下的完整路径和首个可测轮廓；无长度也保留完整拓扑。
struct PreparedTrimMeasurement: Sendable {
    /// 已应用组矩阵和可选完整反向，不能从测量表重建此路径。
    let path: StrokePath
    /// nil表示不存在可测轮廓，非empty裁剪必须保持path。
    let measure: StrokeDashMeasure?
}

/// 单个稳定modifier序号的不可变缓存项，输入和输出始终按原路径ID顺序排列。
final class PreparedTrimBatch: Sendable {
    /// 生成器值、源路径身份/矩阵或前序Trim身份，不深比较点列。
    let inputs: [ShapeContour]
    /// Float逐位比例、模式和反向决定输出是否能直接复用。
    let selection: TrimSelection
    /// nil为empty/unchanged快路径；非nil时与inputs一一对应。
    let measurements: [PreparedTrimMeasurement]?
    /// 完整成功后的结果；与inputs等长，空路径仍占原槽位。
    let outputs: [ShapeContour]
    /// 包括全部输入、输出和测量表的保活成本，共享数组允许保守重计。
    let estimatedBytes: Int

    /// 只有批次完整成功才发布；计入测量记录和引用的原生曲线，取消不返回半份结果。
    init(inputs: [ShapeContour], selection: TrimSelection, measurements: [PreparedTrimMeasurement]?,
         outputs: [ShapeContour]) throws {
        var cost = FramePlanBudget(limit: Int.max, resourceName: "maximumTrimBytes")
        try cost.reserve(stride: 256)
        for contours in [inputs, outputs] {
            try cost.reserve(count: contours.count, stride: 192)
            for contour in contours {
                try Task.checkCancellation()
                try cost.reserve(stride: contour.referencedBytes)
            }
        }
        if let measurements {
            try cost.reserve(count: measurements.count, stride: 256)
            for value in measurements {
                try Task.checkCancellation()
                try PreparedTrimPath.retain(value.path, budget: &cost)
                if let measure = value.measure {
                    try cost.reserve(count: measure.curves.count, stride: 128)
                    try cost.reserve(count: measure.records.count, stride: 32)
                }
            }
        }
        self.inputs = inputs
        self.selection = selection
        self.measurements = measurements
        self.outputs = outputs
        estimatedBytes = cost.used
    }
}
