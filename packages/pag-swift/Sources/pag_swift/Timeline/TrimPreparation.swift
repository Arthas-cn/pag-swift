/// 单个modifier的批次裁剪；复用完整输出或测量表，不创建显示对象或改变原路径ID顺序。
enum TrimPreparation {
    /// 候选须来自同源同modifier且至多四份；全过程共用调用方预算，失败不发布半份batch。
    static func prepare(_ contours: [ShapeContour], selection: TrimSelection,
                        reusing candidates: [PreparedTrimBatch],
                        budget: inout GeometryBudget) throws -> PreparedTrimBatch {
        try budget.consume()
        guard candidates.count <= 4 else { throw PAGError.invalidArgument("trimReuseCandidates") }
        var reused: [PreparedTrimMeasurement]?
        for candidate in candidates {
            guard try matches(candidate.inputs, contours, budget: &budget) else { continue }
            if candidate.selection == selection {
                try budget.reserve(stride: candidate.estimatedBytes)
                return candidate
            }
            if candidate.selection.reversed == selection.reversed, reused == nil {
                reused = candidate.measurements
            }
        }
        let measurements: [PreparedTrimMeasurement]?
        let outputs: [ShapeContour]
        switch selection {
        case .empty:
            measurements = nil
            var writer = TrimPathWriter(budget: budget)
            defer { budget = writer.budget }
            let empty = try PreparedTrimPath(writer.finish())
            try writer.budget.reserve(contours.count, stride: 192)
            outputs = Array(repeating: .trimmed(empty), count: contours.count)
        case .unchanged(reversed: false):
            measurements = nil
            outputs = contours
        case .unchanged(reversed: true):
            measurements = nil
            try budget.reserve(contours.count, stride: 192)
            outputs = try contours.map {
                let path = try TrimPathConversion.make($0, budget: &budget)
                return .trimmed(try PreparedTrimPath(TrimPathReversal.reversed(path, budget: &budget)))
            }
        case let .ranges(mode, reversed, first, second):
            let values = try reused ?? measure(contours, reversed: reversed, budget: &budget)
            measurements = values
            outputs = try apply(values, mode: mode, reversed: reversed, first: first, second: second, budget: &budget)
        }
        let result = try PreparedTrimBatch(inputs: contours, selection: selection, measurements: measurements, outputs: outputs)
        // 临时工作和完整保活分别计费；命中也走同一完整成本，不能让缓存绕过调用方上限。
        try budget.reserve(stride: result.estimatedBytes)
        return result
    }

    /// 参数/引用身份匹配按输入数量计工作，不读取源路径或旧输出的点数组。
    private static func matches(_ first: [ShapeContour], _ second: [ShapeContour],
                                budget: inout GeometryBudget) throws -> Bool {
        guard first.count == second.count else { return false }
        for (lhs, rhs) in zip(first, second) {
            try budget.consume()
            guard lhs.matches(rhs) else { return false }
        }
        return true
    }

    /// 每条路径先完整反向再找首个可测轮廓；measure=nil仍保留规范化后的全部拓扑。
    private static func measure(_ contours: [ShapeContour], reversed: Bool,
                                budget: inout GeometryBudget) throws -> [PreparedTrimMeasurement] {
        try budget.reserve(contours.count, stride: 256)
        var result: [PreparedTrimMeasurement] = []
        for contour in contours {
            try budget.consume()
            var path = try TrimPathConversion.make(contour, budget: &budget)
            if reversed { path = try TrimPathReversal.reversed(path, budget: &budget) }
            let measure = try TrimPathMeasurement.first(in: path, budget: &budget)
            result.append(PreparedTrimMeasurement(path: path, measure: measure))
        }
        return result
    }

    /// 源Float的求和及距离分配；反向Individual逆序遍历，但结果写回原槽位。
    private static func apply(_ values: [PreparedTrimMeasurement], mode: SourceTrimMode, reversed: Bool,
                              first: TrimInterval, second: TrimInterval?,
                              budget: inout GeometryBudget) throws -> [ShapeContour] {
        try budget.reserve(values.count, stride: 192)
        var outputs: [ShapeContour] = []
        for value in values {
            // 命中测量时也逐项检查取消和工作，不能先无界创建全部输出包装。
            try budget.consume()
            try budget.reserve(stride: 128)
            outputs.append(.trimmed(try PreparedTrimPath(value.path)))
        }
        var total: Float = 0
        let backwards = mode == .individually && reversed
        if mode == .individually {
            for position in values.indices {
                try budget.consume()
                let index = backwards ? values.count - 1 - position : position
                total = try finite(total + (values[index].measure?.length ?? 0))
            }
        }
        let globalFirst = try mode == .individually ? scaled(first, by: total) : first
        let globalSecond = try mode == .individually ? second.map { try scaled($0, by: total) } : second
        var added: Float = 0
        for position in values.indices {
            try budget.consume()
            let index = backwards ? values.count - 1 - position : position
            // 两种模式都保留零长度路径，不能把Move/零Line当成没有输入。
            guard let measure = values[index].measure else { continue }
            let end = try finite(added + measure.length)
            var writer = TrimPathWriter(budget: budget)
            defer { budget = writer.budget }
            try append(globalFirst, mode: mode, measure: measure, added: added, end: end, to: &writer)
            if let globalSecond {
                try append(globalSecond, mode: mode, measure: measure, added: added, end: end, to: &writer)
            }
            outputs[index] = .trimmed(try PreparedTrimPath(writer.finish()))
            // 只有Individual累计前缀；Simultaneously不能因其他输入总长溢出而失败。
            if mode == .individually { added = end }
        }
        return outputs
    }

    /// Individual先过滤相触区间，Simultaneous直接提取并保留端点零Line，不能共用相交判断。
    private static func append(_ interval: TrimInterval, mode: SourceTrimMode, measure: StrokeDashMeasure,
                               added: Float, end: Float, to writer: inout TrimPathWriter) throws {
        let distance: TrimInterval
        if mode == .individually {
            if added >= interval.end || end <= interval.start { return }
            distance = TrimInterval(start: try finite(interval.start - added), end: try finite(interval.end - added))
        } else {
            distance = try scaled(interval, by: measure.length)
        }
        _ = try TrimPathMeasurement.append(measure, from: distance.start, to: distance.end, to: &writer)
    }

    /// Float乘积不改用Double，也不把非有限值夹成合法距离。
    private static func scaled(_ interval: TrimInterval, by length: Float) throws -> TrimInterval {
        TrimInterval(start: try finite(interval.start * length), end: try finite(interval.end * length))
    }

    /// 新增累计和距离运算的非有限值统一报告Trim精度失败，既有内核错误不经过此处。
    private static func finite(_ value: Float) throws -> Float {
        guard value.isFinite else { throw PAGError.renderingFailure("trimPrecision") }
        return value
    }
}

/// 缓存测量只依赖完整路径的方向，模式与裁剪比例不改变测量表。
private extension TrimSelection {
    /// empty不需要测量；返回false仅便于候选搜索，不会在empty分支使用找到的表。
    var reversed: Bool {
        switch self {
        case .empty: false
        case .unchanged(let reversed), .ranges(_, let reversed, _, _): reversed
        }
    }
}
