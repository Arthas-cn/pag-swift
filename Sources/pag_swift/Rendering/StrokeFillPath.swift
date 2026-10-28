/// hairline临时路径到最终填充路径的有界出口；只转换曲线表示，不描边、闭合或修补退化点。
enum StrokeFillPath {
    /// 保留原指令拓扑并把Quad/Conic转为Double Cubic；矩阵只参与误差评估，由拥有者统一复原一次。
    static func append(_ path: StrokePath, restoration: SceneAffine, tolerance: Double,
                       to output: StrokePathOutput) throws {
        try output.budget.consume()
        guard tolerance.isFinite, tolerance > 0 else { throw PAGError.invalidArgument("geometryTolerance") }
        var current: ScenePoint?
        var index = 0
        for verb in path.verbs {
            try output.budget.consume(1 + verb.pointCount)
            switch verb {
            case .move, .line, .cubic:
                let target: SourcePathVerb
                switch verb {
                case .move: target = .move
                case .line: target = .line
                default: target = .cubic
                }
                try output.budget.reserve(verb.pointCount, stride: 32)
                let points = Array(path.points[index..<(index + verb.pointCount)])
                try output.append(target, points: points)
                current = points.last
            case .quad, .conic:
                guard let start = current else { throw PAGError.renderingFailure("strokePathSequence") }
                let weight: Float
                if case .conic(let value) = verb { weight = value }
                else { weight = 1 }
                // 此处才允许转换表示；保留Double原点，不经过Float采样、描边或测量叶弦。
                try output.budget.reserve(stride: 512)
                let end = path.points[index + 1]
                let curve = StrokeConic(points: [start, path.points[index], end], weights: [1, Double(weight), 1])
                let cubics = try StrokeConicApproximation.cubics(curve, tolerance: tolerance,
                                                               transform: restoration, budget: &output.budget)
                for cubic in cubics { try output.append(.cubic, points: [cubic.first, cubic.second, cubic.end]) }
                current = end
            case .close:
                try output.append(.close)
                // 规范化临时路径在Close后必须重新Move；不擅自补闭合线或下一段起点。
                current = nil
            }
            index += verb.pointCount
        }
    }
}
