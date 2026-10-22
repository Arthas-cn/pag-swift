/// Repeater只克隆已求值的当前组；原先的Trim/Merge结果和paint覆盖顺序不能重算。
extension ShapeContentPreparation {
    /// 用有界复制列表替换此前节点；失败时本次Shape准备整体丢弃。
    mutating func applyRepeater(_ source: SourceRepeater, nodes: inout [ShapeContentNode], depth: Int) throws {
        switch try RepeaterSampling.select(source, at: frame, budget: &budget) {
        case .unchanged:
            return
        case .cleared:
            nodes.removeAll()
        case .copies(let copies):
            let original = nodes
            var repeated: [ShapeContentNode] = []
            try budget.reserve(count: copies.count, stride: 128)
            repeated.reserveCapacity(copies.count)
            for copy in copies {
                try Task.checkCancellation()
                let children = try clone(original, applying: copy.matrix, depth: depth + 1)
                repeated.append(.group(opacity: copy.opacity, children: children))
            }
            nodes = repeated
        }
    }

    /// 按源组层级克隆节点，并将重复变换后乘到每条路径和paint矩阵。
    private mutating func clone(_ nodes: [ShapeContentNode], applying matrix: SceneAffine,
                                depth: Int) throws -> [ShapeContentNode] {
        guard depth <= 64 else { throw PAGError.resourceLimitExceeded("maximumShapeDepth") }
        try budget.reserve(count: nodes.count, stride: 128)
        var result: [ShapeContentNode] = []
        result.reserveCapacity(nodes.count)
        for node in nodes {
            try Task.checkCancellation()
            switch node {
            case .path(let id):
                guard paths.indices.contains(id) else { throw SceneValidator.invalid("invalidShapePathSlot") }
                let contour = try cloneContour(paths[id], applying: matrix)
                try budget.reserve(stride: 192)
                let newID = paths.count
                paths.append(contour)
                result.append(.path(newID))
            case .paint(let source, let paintMatrix):
                // 克隆仍保留完整材料和矩阵，不能只按indirect节点外壳计费。
                try budget.reserve(stride: max(512,
                    MemoryLayout<ShapeSourcePaint>.stride + MemoryLayout<SceneAffine>.stride + 128))
                result.append(.paint(source, matrix: try paintMatrix.following(matrix)))
            case .group(let opacity, let children):
                result.append(.group(opacity: opacity,
                                     children: try clone(children, applying: matrix, depth: depth + 1)))
            }
        }
        return result
    }

    /// 非Trim轮廓只换累计矩阵；已裁剪曲线必须变换点列，不重新测量路径长度。
    private mutating func cloneContour(_ contour: ShapeContour, applying matrix: SceneAffine) throws -> ShapeContour {
        switch contour {
        case .rectangle(let value):
            return .rectangle(RoundedRectangleContour(left: value.left, top: value.top,
                right: value.right, bottom: value.bottom, radius: value.radius,
                reversed: value.reversed, matrix: try value.matrix.following(matrix)))
        case .ellipse(let value):
            return .ellipse(EllipseContour(left: value.left, top: value.top, right: value.right,
                bottom: value.bottom, reversed: value.reversed, matrix: try value.matrix.following(matrix)))
        case .polyStar(let value):
            return .polyStar(PolyStarContour(kind: value.kind, reversed: value.reversed, points: value.points,
                position: value.position, rotation: value.rotation, innerRadius: value.innerRadius,
                outerRadius: value.outerRadius, innerRoundness: value.innerRoundness,
                outerRoundness: value.outerRoundness, matrix: try value.matrix.following(matrix)))
        case .path(let source, let sourceMatrix):
            return .path(source, matrix: try sourceMatrix.following(matrix))
        case .trimmed(let trimmed):
            try geometryBudget.reserve(trimmed.path.points.count, stride: 32)
            var points: [ScenePoint] = []
            points.reserveCapacity(trimmed.path.points.count)
            for point in trimmed.path.points {
                try geometryBudget.consume()
                points.append(try matrix.applying(to: point))
            }
            let path = try StrokePath(verbs: trimmed.path.verbs, points: points, budget: &geometryBudget)
            let copy = try PreparedTrimPath(path)
            try budget.reserve(stride: copy.estimatedBytes)
            return .trimmed(copy)
        }
    }
}
