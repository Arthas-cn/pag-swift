/// 第一遍只保存源paint及其原组坐标，第二遍才引用完成全部modifier的路径。
enum ShapeSourcePaint: Sendable {
    /// 普通颜色填充，不冻结当前路径数组。
    case fill(SourceFill)
    /// 描边样式仍在第二遍按同一源帧求值。
    case stroke(SourceStroke)
    /// 渐变填充的颜色程序保持独立缓存。
    case gradientFill(SourceGradientFill)
    /// 渐变描边保留原paint矩阵供逆变换与材料映射。
    case gradientStroke(SourceGradientStroke)
}

/// 单次同步准备的有界内容树；路径只存ID，避免为每个paint复制前缀。
indirect enum ShapeContentNode: Sendable {
    /// 指向本次准备局部路径表的稳定槽位。
    case path(Int)
    /// 保留原paint材料与累计矩阵，之后的Trim也能改变它将读取的路径。
    case paint(ShapeSourcePaint, matrix: SceneAffine)
    /// 子组只持有整体透明度和源顺序节点，路径可以继续参与父组paint。
    case group(opacity: Double, children: [ShapeContentNode])
}

/// 两阶段准备的第一遍；局部可变路径表只在成功后交给第二遍，不进入store。
struct ShapeContentPreparation {
    /// 节点、ID表和完整Trim保活成本均先扣减此帧计划预算。
    var budget: FramePlanBudget
    /// 整个源层的所有modifier共用，不能按路径或子组重置。
    var geometryBudget: GeometryBudget
    /// 属性采样使用所属合成帧，不减图层起点。
    let frame: Int64
    /// 至多四个同源旧采样，按稳定modifier序号查找。
    let candidates: [PreparedShapeLayer]
    /// 所有路径的最终候选，节点持有下标；连续Trim按源顺序替换槽位。
    var paths: [ShapeContour] = []
    /// 完整批次才入局部表，最终随PreparedShapeLayer原子发布。
    var trimBatchesByModifier: [Int: PreparedTrimBatch] = [:]
    /// 深度优先源modifier序号，不因透明度或空路径而跳号。
    private var nextModifierOrdinal = 0

    /// 接收单次准备的两份预算；不创建actor、任务或新的逐路径资源额度。
    init(budget: FramePlanBudget, geometryBudget: GeometryBudget, frame: Int64, candidates: [PreparedShapeLayer]) {
        self.budget = budget
        self.geometryBudget = geometryBudget
        self.frame = frame
        self.candidates = candidates
    }

    /// 按源顺序建树并应用modifier；重型属性求值留在非递归辅助中以保留64层Debug边界。
    mutating func group(_ elements: [SourceShape], matrix: SceneAffine, depth: Int) throws -> [ShapeContentNode] {
        try Task.checkCancellation()
        guard depth <= 64 else { throw PAGError.resourceLimitExceeded("maximumShapeDepth") }
        try budget.reserve(stride: 256)
        var nodes: [ShapeContentNode] = []
        for element in elements {
            try Task.checkCancellation()
            if let node = try leaf(element, matrix: matrix) {
                try budget.reserve(stride: 128)
                nodes.append(node)
                continue
            }
            switch element {
            case .group(let transform, let children):
                let value = try groupTransform(transform)
                let child = try group(children, matrix: value.matrix.following(matrix), depth: depth + 1)
                try budget.reserve(stride: 128)
                nodes.append(.group(opacity: value.opacity, children: child))
            case .trimPaths(let source):
                try trim(source, nodes: nodes)
            default:
                // 只有真正无verb的源Path会落到这里，不制造一个可被paint引用的空源轮廓。
                continue
            }
        }
        return nodes
    }

    /// 非递归求组矩阵，避免大属性临时值留在64层调用栈上。
    private func groupTransform(_ source: SourceShapeTransformProperties) throws -> (matrix: SceneAffine, opacity: Double) {
        let value = try TransformEvaluation.shape(source.value(at: frame))
        return (value.matrix, value.opacity)
    }

    /// 路径与paint节点共用源顺序；modifier/group由有界递归层处理。
    private mutating func leaf(_ element: SourceShape, matrix: SceneAffine) throws -> ShapeContentNode? {
        if let contour = try contour(for: element, matrix: matrix) {
            try budget.reserve(stride: 192)
            let index = paths.count
            paths.append(contour)
            return .path(index)
        }
        switch element {
        case .fill(let value): return try paintNode(.fill(value), matrix: matrix)
        case .stroke(let value): return try paintNode(.stroke(value), matrix: matrix)
        case .gradientFill(let value): return try paintNode(.gradientFill(value), matrix: matrix)
        case .gradientStroke(let value): return try paintNode(.gradientStroke(value), matrix: matrix)
        default: return nil
        }
    }

    /// indirect节点在构造前计入完整内联材料、矩阵与保守box开销，透明/无路径paint也不能漏费。
    private mutating func paintNode(_ source: ShapeSourcePaint, matrix: SceneAffine) throws -> ShapeContentNode {
        let bytes = max(512, MemoryLayout<ShapeSourcePaint>.stride + MemoryLayout<SceneAffine>.stride + 128)
        try budget.reserve(stride: bytes)
        return .paint(source, matrix: matrix)
    }

    /// 只收集当前组已出现的路径ID；此前子组和paint也会在第二遍看到更新，未来路径不参与。
    private mutating func trim(_ source: SourceTrimPaths, nodes: [ShapeContentNode]) throws {
        try budget.reserve(stride: 16)
        let ordinal = nextModifierOrdinal
        let next = ordinal.addingReportingOverflow(1)
        guard !next.overflow else { throw PAGError.resourceLimitExceeded("maximumShapeModifiers") }
        nextModifierOrdinal = next.partialValue
        try budget.reserve(count: nodes.count, stride: 128)
        var stack = Array(nodes.reversed())
        var ids: [Int] = []
        var inputs: [ShapeContour] = []
        while let node = stack.popLast() {
            try geometryBudget.consume()
            switch node {
            case .path(let id):
                try budget.reserve(stride: 208)
                ids.append(id)
                inputs.append(paths[id])
            case .group(_, let children):
                try budget.reserve(count: children.count, stride: 128)
                stack.append(contentsOf: children.reversed())
            case .paint: continue
            }
        }
        try budget.reserve(count: candidates.count, stride: 16)
        let previous = candidates.compactMap { $0.trimBatchesByModifier[ordinal] }
        let selection = try TrimEvaluation.selection(source, at: frame)
        let batch = try TrimPreparation.prepare(inputs, selection: selection, reusing: previous, budget: &geometryBudget)
        try budget.reserve(stride: batch.estimatedBytes)
        try budget.reserve(stride: 64)
        // 全部校验通过后才替换候选槽位；任何失败都会丢掉整个第一遍，不向store发布部分树。
        for (id, output) in zip(ids, batch.outputs) {
            try geometryBudget.consume()
            paths[id] = output
        }
        trimBatchesByModifier[ordinal] = batch
    }

    /// 非递归求值一项轮廓并预付保活成本；paint/group和空Path返回nil，不改累计快照。
    private mutating func contour(for element: SourceShape, matrix: SceneAffine) throws -> ShapeContour? {
        try Task.checkCancellation()
        switch element {
        case .rectangle(let source):
            let contour = try RoundedRectangleContour.make(size: PropertyEvaluation.point(source.size, at: frame),
                position: PropertyEvaluation.point(source.position, at: frame),
                roundness: PropertyEvaluation.scalar(source.roundness, at: frame),
                reversed: source.reversed, matrix: matrix)
            try budget.reserve(stride: 192)
            return .rectangle(contour)
        case .ellipse(let source):
            try budget.reserve(stride: 192)
            return .ellipse(try EllipseContour.make(source, at: frame, matrix: matrix))
        case .polyStar(let source):
            try budget.reserve(stride: 192)
            return .polyStar(try PolyStarContour.make(source, at: frame, matrix: matrix))
        case .path(let property):
            let path = try PropertyEvaluation.path(property, at: frame, budget: &budget)
            // 奇异变换仍可能留下可描边中心线；只有真正没有verb的路径才能省略。
            guard !path.verbs.isEmpty else { return nil }
            // 采样结果和网格缓存会保活共享源路径，不能只给轮廓外壳计费。
            try budget.reserve(stride: 192)
            try budget.reserve(stride: path.estimatedBytes)
            for point in path.points {
                try Task.checkCancellation()
                _ = try matrix.applying(to: point)
            }
            return .path(path, matrix: matrix)
        case .fill, .stroke, .gradientFill, .gradientStroke, .group, .trimPaths:
            return nil
        }
    }

}
