/// 后台描边临时路径的指令；保留曲线类型，不扩充PAG字节模型或最终填充路径。
enum StrokePathVerb: Sendable, Equatable {
    /// 开始独立子路径，消费一个起点；连续或尾随Move合法。
    case move
    /// 从当前点连接一条直线，消费一个终点，包括零长度线。
    case line
    /// 从当前点连接二次曲线，依次消费控制点与终点，没有有理权重。
    case quad
    /// 从当前点连接有理二次曲线，消费控制点与终点；关联值是源Float中间权重。
    case conic(weight: Float)
    /// 从当前点连接三次曲线，依次消费两个控制点与终点。
    case cubic
    /// 关闭尚未关闭的子路径，不消费点；后续绘制必须先开始新Move。
    case close

    /// 指令在平行点数组中占用的数量，Quad和Conic都不重复存储当前起点。
    var pointCount: Int {
        switch self {
        case .move, .line: 1
        case .quad, .conic: 2
        case .cubic: 3
        case .close: 0
        }
    }

    /// 按源conicTo将权重1归为Quad；其他非法权重直接失败，不修补成另一条几何路径。
    func normalized() throws -> Self {
        guard case let .conic(weight) = self else { return self }
        guard weight.isFinite, weight > 0 else { throw PAGError.invalidArgument("strokeConicWeight") }
        return weight == 1 ? .quad : self
    }
}

/// 不可变的后台描边中心线或dash结果；结构规范化且保留Quad/Conic，不提供有损降级出口。
struct StrokePath: Sendable {
    /// 完整验证后的指令；已将所有权重恰为1的Conic归为Quad。
    let verbs: [StrokePathVerb]
    /// 与指令数量严格匹配的有限Double点，保留调用方坐标精度与重复点。
    let points: [ScenePoint]

    /// 验证布局、次序、点和权重后保存；预算在数组增长前计费，失败或取消保留已耗工作。
    init(verbs: [StrokePathVerb], points: [ScenePoint], budget: inout GeometryBudget) throws {
        try budget.consume()
        try budget.reserve(stride: 128)
        try budget.reserve(verbs.count, stride: 16)
        try budget.reserve(points.count, stride: 32)
        var normalized: [StrokePathVerb] = []
        normalized.reserveCapacity(verbs.count)
        var pointIndex = 0
        var isOpen = false
        for verb in verbs {
            try budget.consume()
            guard verb.pointCount <= points.count - pointIndex else {
                throw PAGError.invalidArgument("strokePathPoints")
            }
            // 这里只验证已规范化的临时输入，不替builder猜测缺失的Move或连续Close。
            if verb == .move { isOpen = true }
            else {
                guard isOpen else { throw PAGError.invalidArgument("strokePathSequence") }
                if verb == .close { isOpen = false }
            }
            let value = try verb.normalized()
            for index in pointIndex..<(pointIndex + verb.pointCount) {
                try budget.consume()
                let point = points[index]
                guard point.x.isFinite, point.y.isFinite else { throw PAGError.invalidArgument("strokePathPoint") }
            }
            normalized.append(value)
            pointIndex += verb.pointCount
        }
        guard pointIndex == points.count else { throw PAGError.invalidArgument("strokePathPoints") }
        self.verbs = normalized
        self.points = points
    }
}
