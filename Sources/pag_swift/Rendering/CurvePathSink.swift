/// 纯曲线生成器的同步写入边界；具体writer决定接纳政策，几何公式不引入描边限额。
protocol CurvePathSink {
    /// 当前完整准备共享的工作和内存预算，不得在每条曲线重新初始化。
    var budget: GeometryBudget { get set }
    /// 追加一个指令及其恰好匹配的点，增长前计费；错误与取消原样传播。
    mutating func append(_ verb: StrokePathVerb, points: [ScenePoint]) throws
}

/// 源路径规范化和坐标映射的共同步骤；Stroke与Trim使用各自writer的接纳政策。
extension CurvePathSink {
    /// 追加已在图层坐标的规范化曲线，只施加可选逆paint矩阵，不重复组变换或Float恒等映射。
    mutating func append(_ path: StrokePath, inverse: StrokeFloatTransform?) throws {
        var index = 0
        for verb in path.verbs {
            try budget.consume()
            try budget.reserve(verb.pointCount, stride: 32)
            var points: [ScenePoint] = []
            for point in path.points[index..<(index + verb.pointCount)] {
                points.append(try inverse?.applying(to: point) ?? point)
            }
            try append(verb, points: points)
            index += verb.pointCount
        }
    }

    /// 追加无点的Close等指令，具体结构验证仍由writer和StrokePath负责。
    mutating func append(_ verb: StrokePathVerb) throws {
        try append(verb, points: [])
    }

    /// 追加一条独立源路径；初始Line补原点，close后Line补最近Move，不连接上一条路径。
    mutating func append(_ path: SourcePath, matrix: StrokeFloatTransform, inverse: StrokeFloatTransform?) throws {
        var start = ScenePoint.zero
        var open = false
        var hasMove = false
        var index = 0
        for verb in path.verbs {
            try budget.consume()
            if verb == .line || verb == .cubic {
                if !open {
                    try append(.move, points: [mapped(start, matrix: matrix, inverse: inverse)])
                    open = true
                    hasMove = true
                }
            }
            switch verb {
            case .move:
                start = path.points[index]
                try append(.move, points: [mapped(start, matrix: matrix, inverse: inverse)])
                open = true
                hasMove = true
            case .line:
                try append(.line, points: [mapped(path.points[index], matrix: matrix, inverse: inverse)])
            case .cubic:
                try append(.cubic, points: [mapped(path.points[index], matrix: matrix, inverse: inverse),
                    mapped(path.points[index + 1], matrix: matrix, inverse: inverse),
                    mapped(path.points[index + 2], matrix: matrix, inverse: inverse)])
            case .close:
                // 空Close和连续Close不新增轮廓；Move+Close必须保留，后续Stroke可能产生端点。
                if hasMove && open { try append(.close) }
                open = false
            }
            index += verb.pointCount
        }
    }

    /// 顺序执行组坐标与可选逆paint变换；两次Float舍入不可约为一个Double乘积。
    func mapped(_ point: ScenePoint, matrix: StrokeFloatTransform, inverse: StrokeFloatTransform?) throws -> ScenePoint {
        let layer = try matrix.applying(to: point)
        return try inverse?.applying(to: layer) ?? layer
    }
}
