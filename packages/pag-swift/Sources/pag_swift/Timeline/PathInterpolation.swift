/// PathData::interpolate的纯Swift值实现；只求几何形变，不决定图层时间或显示资格。
enum PathInterpolation {
    /// 按Float分量次序插值，line/cubic配对时补退化控制点；非法拓扑、非有限结果、预算和取消均失败。
    static func interpolate(_ first: SourcePath, _ second: SourcePath, progress: Float,
                            budget: inout FramePlanBudget) throws -> SourcePath {
        try first.validateInterpolation(to: second)
        guard progress.isFinite else { throw SceneValidator.invalid("unrepresentablePropertyValue") }
        try budget.reserve(stride: 128)
        // 源PathData在任一端为空时不写任何输出；不能为形变擅自复制另一端。
        guard !first.verbs.isEmpty, !second.verbs.isEmpty else { return try SourcePath(verbs: [], points: []) }
        try budget.reserve(count: first.verbs.count, stride: 128)
        var verbs: [SourcePathVerb] = []
        var points: [ScenePoint] = []
        var a = 0
        var b = 0
        for (left, right) in zip(first.verbs, second.verbs) {
            try Task.checkCancellation()
            if left == right {
                verbs.append(left)
                for index in 0..<left.pointCount {
                    points.append(try point(first.points[a + index], second.points[b + index], progress: progress))
                }
            } else {
                verbs.append(.cubic)
                for index in 0..<3 {
                    let lhs = left == .cubic ? first.points[a + index] : first.points[index == 0 ? a - 1 : a]
                    let rhs = right == .cubic ? second.points[b + index] : second.points[index == 0 ? b - 1 : b]
                    points.append(try point(lhs, rhs, progress: progress))
                }
            }
            a += left.pointCount
            b += right.pointCount
        }
        return try SourcePath(verbs: verbs, points: points)
    }

    /// 保持Interpolate<Point/float>的中间精度，最终扩为Double；溢出不是空路径。
    private static func point(_ first: ScenePoint, _ second: ScenePoint, progress: Float) throws -> ScenePoint {
        let x = Float(first.x) + (Float(second.x) - Float(first.x)) * progress
        let y = Float(first.y) + (Float(second.y) - Float(first.y)) * progress
        guard x.isFinite, y.isFinite else { throw SceneValidator.invalid("unrepresentablePropertyValue") }
        return ScenePoint(x: Double(x), y: Double(y))
    }
}
