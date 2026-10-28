/// PAG路径的规范化指令；压缩H/V和省略控制点在读取时展开，不包含GPU或平台路径。
enum SourcePathVerb: Sendable, Equatable {
    /// 开始一个子路径，消费一个起点。
    case move
    /// 从当前点连接直线，消费一个终点。
    case line
    /// 连接三次曲线，依次消费两个控制点和终点。
    case cubic
    /// 闭合当前子路径，不消费点，也不改变源点数组。
    case close

    /// 此指令在独立点数组中占用的元素数，供布局验证和动画配对使用。
    var pointCount: Int {
        switch self {
        case .move, .line: 1
        case .cubic: 3
        case .close: 0
        }
    }
}

/// 不可变的源路径值；动画端点和静态路径可共享，不维护当前点或上次采样状态。
final class SourcePath: Sendable {
    /// 按文件顺序保存的规范化指令，空数组表示空路径。
    let verbs: [SourcePathVerb]
    /// 指令引用的有限场景点；解码来源为Float，后台生成的矢量轮廓保留Double，数组数量与指令严格匹配。
    let points: [ScenePoint]
    /// 路径对象与指令/点数组的保守留存成本；构造时检查整数溢出，不代表allocator实际驻留量。
    let estimatedBytes: Int

    /// 验证指令/点布局和有限性后保存；取消或损坏输入不发布部分路径，调用方先计分配预算。
    init(verbs: [SourcePathVerb], points: [ScenePoint]) throws {
        try Task.checkCancellation()
        let verbBytes = verbs.count.multipliedReportingOverflow(by: 8)
        let pointBytes = points.count.multipliedReportingOverflow(by: 32)
        let arrays = verbBytes.partialValue.addingReportingOverflow(pointBytes.partialValue)
        let total = arrays.partialValue.addingReportingOverflow(128)
        guard !verbBytes.overflow, !pointBytes.overflow, !arrays.overflow, !total.overflow else {
            throw PAGError.resourceLimitExceeded("maximumPathBytes")
        }
        var consumed = 0
        for verb in verbs {
            try Task.checkCancellation()
            guard verb.pointCount <= points.count - consumed else { throw SceneValidator.invalid("invalidPathPoints") }
            consumed += verb.pointCount
        }
        guard consumed == points.count else { throw SceneValidator.invalid("invalidPathPoints") }
        for point in points {
            try Task.checkCancellation()
            guard point.x.isFinite, point.y.isFinite else { throw SceneValidator.invalid("nonFinitePathPoint") }
        }
        self.verbs = verbs
        self.points = points
        estimatedBytes = total.partialValue
    }

    /// 非Hold段必须可逐指令形变；空端点沿源码允许，非空端点只允许line/cubic类型差异。
    func validateInterpolation(to other: SourcePath) throws {
        try Task.checkCancellation()
        guard !verbs.isEmpty, !other.verbs.isEmpty else { return }
        guard verbs.count == other.verbs.count else { throw SceneValidator.invalid("incompatiblePathTopology") }
        var firstIndex = 0
        var secondIndex = 0
        for (first, second) in zip(verbs, other.verbs) {
            try Task.checkCancellation()
            if first != second {
                // 上游GetCurveData在线段升为曲线时取points[index-1]；拒绝没有前点的配对以免越界。
                let isCurvePair = (first == .line && second == .cubic) || (first == .cubic && second == .line)
                guard isCurvePair, firstIndex > 0, secondIndex > 0 else {
                    throw SceneValidator.invalid("incompatiblePathTopology")
                }
            }
            firstIndex += first.pointCount
            secondIndex += second.pointCount
        }
    }
}
