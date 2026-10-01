/// 将源形状在指定合成帧编译为共享解析几何和绘制指令，不读取PAG字节或创建平台路径对象。
enum ShapePreparation {
    /// 完整处理源paint；candidates必须来自同一不变源模板且至多四份，失败仍回传已耗预算。
    static func prepare(_ elements: [SourceShape], at frame: Int64 = 0,
                        reusing candidates: [PreparedShapeLayer] = [],
                        budget: inout FramePlanBudget) throws -> PreparedShapeLayer {
        try Task.checkCancellation()
        guard candidates.count <= 4 else { throw PAGError.invalidArgument("shapeReuseCandidates") }
        let before = budget.used
        try budget.reserve(count: candidates.count, stride: 16)
        var content = ShapeContentPreparation(budget: budget, geometryBudget: try GeometryBudget(),
                                              frame: frame, candidates: candidates)
        let nodes: [ShapeContentNode]
        do {
            nodes = try content.group(elements, matrix: .identity, depth: 0)
        } catch {
            // 第一遍失败也回传节点与保活成本，不能把预算恢复成调用前的值。
            budget = content.budget
            throw error
        }
        var compiler = ShapeCompiler(budget: content.budget, frame: frame, candidates: candidates, paths: content.paths)
        defer { budget = compiler.budget }
        let root = try compiler.group(nodes, opacity: 1, depth: 0)
        let instructions = try compiler.flatten(root.node)
        try Task.checkCancellation()
        return PreparedShapeLayer(instructions: instructions, geometries: compiler.geometries,
            geometryIndicesByPaint: compiler.geometryIndicesByPaint,
            gradientColorizersByPaint: compiler.gradientColorizersByPaint,
            trimBatchesByModifier: content.trimBatchesByModifier, estimatedBytes: compiler.budget.used - before)
    }

    /// 安装时完整扫描元素确定是否依赖采样帧；深度、逻辑工作与取消同样受准备期限制。
    static func isAnimated(_ elements: [SourceShape], depth: Int = 0, budget: inout FramePlanBudget) throws -> Bool {
        try Task.checkCancellation()
        guard depth <= 64 else { throw PAGError.resourceLimitExceeded("maximumShapeDepth") }
        var result = false
        for element in elements {
            try Task.checkCancellation()
            try budget.reserve(stride: 16)
            switch element {
            case .path(let property):
                if property.isAnimated { result = true }
            case .stroke(let stroke):
                if stroke.isAnimated { result = true }
            case .rectangle(let rectangle):
                if rectangle.isAnimated { result = true }
            case .ellipse(let ellipse):
                if ellipse.isAnimated { result = true }
            case .polyStar(let polyStar):
                if polyStar.isAnimated { result = true }
            case .gradientFill(let fill):
                if fill.gradient.isAnimated { result = true }
            case .gradientStroke(let stroke):
                if stroke.isAnimated { result = true }
            case .trimPaths(let trim):
                if trim.isAnimated { result = true }
            case .fill(let fill):
                if fill.isAnimated { result = true }
            case .group(let transform, let children):
                if transform.isAnimated { result = true }
                // 即使已有动画仍扫描后续组，不能让它掩盖越界深度或不可取消的长输入。
                if try isAnimated(children, depth: depth + 1, budget: &budget) { result = true }
            }
        }
        return result
    }
}

/// 单源层的准备状态；路径累计顺序和绘制覆盖顺序分开处理。
private struct ShapeCompiler {
    /// 全部形状层共用的准备预算值，成功或失败都写回调用方。
    var budget: FramePlanBudget
    /// 源合成时间，不减图层起点；ShapePathToPath直接用所属合成帧求值属性。
    let frame: Int64
    /// 至多四份同源旧采样，按最近到最旧顺序查找；仅在本次同步准备中持有。
    let candidates: [PreparedShapeLayer]
    /// 第一遍完成全部modifier后的最终路径表，第二遍只读。
    let paths: [ShapeContour]
    /// 本层已建立的几何快照，数组下标是 fill 的资源身份。
    var geometries: [ShapeGeometry] = []
    /// 所有源fill/stroke的深度优先序号，不随当前可见性改变。
    var nextPaintOrdinal = 0
    /// 实际生成paint的源序号映射；结果发布后用于同源候选匹配。
    var geometryIndicesByPaint: [Int: Int] = [:]
    /// 仅按同源稳定paint序号复用，完整准备成功后随层一起发布。
    var gradientColorizersByPaint: [Int: PreparedGradientColorizer] = [:]

    /// 在不超过 64 层的源组递归中累计路径；rendersContent 为假时仍交出路径但不准备无效 paint。
    mutating func group(_ elements: [ShapeContentNode], opacity: Double,
                        depth: Int, rendersContent: Bool = true) throws -> CompiledShapeGroup {
        try Task.checkCancellation()
        guard depth <= 64 else { throw PAGError.resourceLimitExceeded("maximumShapeDepth") }
        try budget.reserve(stride: 512)
        var contours: [ShapeContour] = []
        var below: [ShapeDrawNode] = []
        var above: [ShapeDrawNode] = []
        var snapshot: Int?
        let emitsPaint = rendersContent && opacity > 0
        for element in elements {
            try Task.checkCancellation()
            switch element {
            case .path(let id):
                try budget.reserve(stride: 192)
                contours.append(paths[id])
                snapshot = nil
            case .paint(let source, let matrix):
                // 原paint矩阵与最终路径分开保存，Stroke不能用Trim的identity替代逆paint变换。
                if let draw = try paint(for: source, contours: contours, matrix: matrix,
                                        emitsPaint: emitsPaint, snapshot: &snapshot) {
                    if draw.order == .abovePrevious { above.append(draw.node) }
                    else { below.append(draw.node) }
                }
            case let .group(alpha, children):
                let child = try group(children, opacity: alpha, depth: depth + 1, rendersContent: emitsPaint)
                // 子组自身 alpha 为零也必须把路径交给父 fill；路径不是已经画好的像素。
                if !child.contours.isEmpty {
                    try budget.reserve(count: child.contours.count, stride: 192)
                    contours.append(contentsOf: child.contours)
                    snapshot = nil
                }
                if let node = child.node {
                    try budget.reserve(stride: 128)
                    below.append(node)
                }
            }
        }
        // ShapeRenderer::RenderShape把Below和子组插头、Above追加；分别累计再拼接避免平方头插成本。
        guard emitsPaint, !below.isEmpty || !above.isEmpty else { return CompiledShapeGroup(contours: contours, node: nil) }
        try budget.reserve(count: below.count, stride: 128)
        try budget.reserve(count: above.count, stride: 128)
        var draws = Array(below.reversed())
        draws.append(contentsOf: above)
        return CompiledShapeGroup(contours: contours, node: .group(opacity: opacity, children: draws))
    }

    /// 一次非递归paint求值；先跳过不可见输入，再编译材料，失败不发布半份缓存。
    mutating func paint(for element: ShapeSourcePaint, contours: [ShapeContour], matrix: SceneAffine,
                        emitsPaint: Bool, snapshot: inout Int?) throws -> (node: ShapeDrawNode, order: ShapeCompositeOrder)? {
        let ordinal = try advancePaint()
        guard emitsPaint, !contours.isEmpty else { return nil }
        let material: ShapeMaterial
        let opacity: Double
        let order: ShapeCompositeOrder
        let stroke: ShapeStroke?
        switch element {
        case .fill(let source):
            let alpha = try PropertyEvaluation.opacity(source.opacity, at: frame)
            // 零alpha不读取无效材料，但保留累计路径和稳定paint序号。
            guard alpha > 0 else { return nil }
            opacity = Double(alpha) / 255
            material = .solid(try PropertyEvaluation.color(source.color, at: frame))
            order = .belowPrevious
            stroke = nil
        case .stroke(let source):
            guard let value = try StrokeEvaluation.evaluate(source, at: frame) else { return nil }
            opacity = value.opacity
            material = .solid(value.color)
            order = value.compositeOrder
            stroke = try ShapeStroke(style: value.style, matrix: matrix)
        case .gradientFill(let source):
            let alpha = try PropertyEvaluation.opacity(source.gradient.opacity, at: frame)
            guard alpha > 0 else { return nil }
            opacity = Double(alpha) / 255
            material = .gradient(try gradient(source.gradient, ordinal: ordinal, matrix: matrix))
            order = source.compositeOrder
            stroke = nil
        case .gradientStroke(let source):
            let alpha = try PropertyEvaluation.opacity(source.gradient.opacity, at: frame)
            guard alpha > 0 else { return nil }
            guard let style = try StrokeEvaluation.style(width: source.width, miterLimit: source.miterLimit,
                cap: source.cap, join: source.join, dashes: source.dashes, at: frame) else { return nil }
            opacity = Double(alpha) / 255
            material = .gradient(try gradient(source.gradient, ordinal: ordinal, matrix: matrix))
            order = source.compositeOrder
            stroke = try ShapeStroke(style: style, matrix: matrix)
        }
        let geometryIndex: Int
        if let stroke {
            geometryIndex = try geometry(for: ordinal, contours: contours, stroke: stroke)
        } else {
            if snapshot == nil { snapshot = try geometry(for: ordinal, contours: contours, stroke: nil) }
            guard let index = snapshot else { throw SceneValidator.invalid("missingShapeGeometry") }
            geometryIndex = index
        }
        try record(ordinal, geometryIndex: geometryIndex)
        try budget.reserve(stride: 128)
        return (.fill(ShapePaint(geometryIndex: geometryIndex, material: material, opacity: opacity)), order)
    }

    /// 收集至多四个同源paint候选，只比较源颜色引用；命中和新程序均预付完整保活成本。
    mutating func gradient(_ source: SourceGradient, ordinal: Int, matrix: SceneAffine) throws -> PreparedGradient {
        try budget.reserve(stride: 128)
        let previous = candidates.compactMap { $0.gradientColorizersByPaint[ordinal] }
        let value = try GradientEvaluation.prepare(source, at: frame, matrix: matrix, reusing: previous, budget: &budget)
        try budget.reserve(stride: 64)
        gradientColorizersByPaint[ordinal] = value.colorizer
        return value
    }

    /// 每个源paint都推进身份，包括透明组和无路径paint；先计费保证序号增长有界。
    mutating func advancePaint() throws -> Int {
        try Task.checkCancellation()
        try budget.reserve(stride: 16)
        let next = nextPaintOrdinal.addingReportingOverflow(1)
        guard !next.overflow else { throw PAGError.resourceLimitExceeded("maximumShapePaints") }
        defer { nextPaintOrdinal = next.partialValue }
        return nextPaintOrdinal
    }

    /// 发布当前可见paint的稳定身份；映射分配先计费，失败不留下可返回的层。
    mutating func record(_ ordinal: Int, geometryIndex: Int) throws {
        try budget.reserve(stride: 64)
        geometryIndicesByPaint[ordinal] = geometryIndex
    }

    /// 优先复用最近同源paint的完整几何；命中也计保活成本，颜色和alpha从不进入几何匹配。
    mutating func geometry(for ordinal: Int, contours: [ShapeContour], stroke: ShapeStroke?) throws -> Int {
        for candidate in candidates {
            try Task.checkCancellation()
            guard let index = candidate.geometryIndicesByPaint[ordinal] else { continue }
            let geometry = candidate.geometries[index]
            if try geometry.matches(contours: contours, stroke: stroke, budget: &budget) {
                try budget.reserve(stride: geometry.estimatedBytes)
                geometries.append(geometry)
                return geometries.count - 1
            }
        }
        try budget.reserve(stride: 128)
        try budget.reserve(count: contours.count, stride: 192)
        for contour in contours {
            try Task.checkCancellation()
            try budget.reserve(stride: contour.referencedBytes)
        }
        if let stroke {
            try budget.reserve(stride: 256)
            try budget.reserve(count: stroke.style.dashes?.intervals.count ?? 0, stride: 16)
        }
        geometries.append(try ShapeGeometry(contours: contours, stroke: stroke))
        return geometries.count - 1
    }

    /// 将准备期有界树转成顺序指令；无变化的 alpha=1 组不用产生空的合成边界。
    mutating func flatten(_ root: ShapeDrawNode?) throws -> [ShapeInstruction] {
        guard let root else { return [] }
        try budget.reserve(stride: 128)
        var stack: [ShapeFlattenStep] = [.node(root)]
        var instructions: [ShapeInstruction] = []
        while let step = stack.popLast() {
            try Task.checkCancellation()
            switch step {
            case .endGroup:
                try budget.reserve(stride: 128)
                instructions.append(.endOpacityGroup)
            case .node(.fill(let paint)):
                try budget.reserve(stride: 128)
                instructions.append(.fill(paint))
            case let .node(.group(opacity, children)):
                if opacity != 1 {
                    try budget.reserve(stride: 256)
                    instructions.append(.beginOpacityGroup(opacity))
                    stack.append(.endGroup)
                }
                try budget.reserve(count: children.count, stride: 128)
                for child in children.reversed() { stack.append(.node(child)) }
            }
        }
        return instructions
    }
}

/// 一组的路径输出和绘制输出；透明或无 paint 的组仍可提供非空 contours。
private struct CompiledShapeGroup {
    /// 带累计组变换的全部子路径，供外层 fill 使用。
    let contours: [ShapeContour]
    /// 当前组自己的画面；nil 表示此组没有可绘制内容，但不代表没有路径。
    let node: ShapeDrawNode?
}

/// 准备阶段的有界绘制树，完成后只保留线性指令，不进入逐帧遍历。
private indirect enum ShapeDrawNode {
    /// 一个有序绘制子组及其整体 alpha。
    case group(opacity: Double, children: [ShapeDrawNode])
    /// 一次填充所引用的完整路径快照。
    case fill(ShapePaint)
}

/// 绘制树线性化的显式栈操作，保持进入/退出组配对。
private enum ShapeFlattenStep {
    /// 访问一项填充或子组。
    case node(ShapeDrawNode)
    /// 子组的全部子内容完成后追加结束指令。
    case endGroup
}
