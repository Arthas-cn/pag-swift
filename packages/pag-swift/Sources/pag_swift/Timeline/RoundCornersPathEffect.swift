import Foundation

/// 按SkCornerPathEffect的线段规则改写原生曲线；既有曲线保持原控制点。
enum RoundCornersPathEffect {
    /// 对每条线段两端最多截半边长，以角点Quad连接；非正半径直接保留源路径。
    static func apply(_ source: StrokePath, radius: Float, budget: inout GeometryBudget) throws -> StrokePath {
        try Task.checkCancellation()
        guard radius.isFinite else { throw SceneValidator.invalid("unrepresentableRoundCornersRadius") }
        guard radius > 0 else { return source }
        var writer = TrimPathWriter(budget: budget)
        defer { budget = writer.budget }
        var pointIndex = 0
        var previous: StrokePathVerb?
        var move = ScenePoint.zero
        var current = ScenePoint.zero
        var lastCorner = ScenePoint.zero
        var firstStep = SIMD2<Float>.zero
        var step = SIMD2<Float>.zero
        var previousIsValid = true
        for (verbIndex, verb) in source.verbs.enumerated() {
            try Task.checkCancellation()
            try writer.budget.consume()
            let count = verb.pointCount
            let points = Array(source.points[pointIndex..<(pointIndex + count)])
            pointIndex += count
            switch verb {
            case .move:
                // 开放轮廓的末个Line被截短，必须补回原终点后再开始下一轮廓。
                if previous == .line { try writer.append(.line, points: [lastCorner]) }
                move = points[0]
                current = move
                let closed = source.verbs[(verbIndex + 1)...].prefix { $0 != .move }.contains(.close)
                if closed { previousIsValid = false }
                else { try writer.append(.move, points: [move]); previousIsValid = true }
            case .line:
                try appendLine(to: points[0], radius: radius, writer: &writer, current: &current,
                               lastCorner: &lastCorner, step: &step, previousIsValid: &previousIsValid)
            case .quad, .conic, .cubic:
                if !previousIsValid {
                    try writer.append(.move, points: [current])
                    previousIsValid = true
                }
                try writer.append(verb, points: points)
                current = points[count - 1]
                lastCorner = current
                firstStep = .zero
            case .close:
                // SkPath::Iter在Close前会合成末点→Move起点的Line，直接Close会漏掉最后一角。
                if current != move {
                    try appendLine(to: move, radius: radius, writer: &writer, current: &current,
                                   lastCorner: &lastCorner, step: &step, previousIsValid: &previousIsValid)
                }
                if firstStep.x != 0 || firstStep.y != 0 {
                    try writer.append(.quad, points: [lastCorner, try point(lastCorner, plus: firstStep)])
                }
                try writer.append(.close, points: [])
                current = move
                previousIsValid = false
            }
            if previous == .move { firstStep = step }
            previous = verb
        }
        if previousIsValid && previous != nil {
            try writer.append(.line, points: [lastCorner])
        }
        return try writer.finish()
    }

    /// 按Skia ComputeStep处理一条显式或Close合成的线段，保留原终点供下一角连接。
    private static func appendLine(to target: ScenePoint, radius: Float, writer: inout TrimPathWriter,
                                   current: inout ScenePoint, lastCorner: inout ScenePoint,
                                   step: inout SIMD2<Float>, previousIsValid: inout Bool) throws {
        let delta = SIMD2<Float>(Float(target.x - current.x), Float(target.y - current.y))
        let distance = hypot(delta.x, delta.y)
        guard distance.isFinite else { throw SceneValidator.invalid("unrepresentableRoundCornersPath") }
        let drawSegment = distance > radius * 2
        step = drawSegment ? delta * (radius / distance) : delta * 0.5
        let leading = try point(current, plus: step)
        if !previousIsValid {
            try writer.append(.move, points: [leading])
            previousIsValid = true
        } else {
            try writer.append(.quad, points: [current, leading])
        }
        if drawSegment { try writer.append(.line, points: [try point(target, minus: step)]) }
        current = target
        lastCorner = target
    }

    /// 使用Skia的Float步进求点；溢出不能被Double转换悄悄掩盖。
    private static func point(_ origin: ScenePoint, plus step: SIMD2<Float>) throws -> ScenePoint {
        let x = Float(origin.x) + step.x
        let y = Float(origin.y) + step.y
        guard x.isFinite, y.isFinite else { throw SceneValidator.invalid("unrepresentableRoundCornersPath") }
        return ScenePoint(x: Double(x), y: Double(y))
    }

    /// 同一Float步进的反向端点；不改变源线段的原始终点。
    private static func point(_ origin: ScenePoint, minus step: SIMD2<Float>) throws -> ScenePoint {
        try point(origin, plus: -step)
    }
}
