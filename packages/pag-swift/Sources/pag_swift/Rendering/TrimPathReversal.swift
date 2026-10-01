/// SkPath::reverseAddPath的完整路径反转；保留Move/Close/零段，不提前应用可测轮廓筛选。
enum TrimPathReversal {
    /// 同时反转轮廓与边的顺序，控制点相应交换；输入须为已验证StrokePath，失败或取消无输出。
    static func reversed(_ path: StrokePath, budget: inout GeometryBudget) throws -> StrokePath {
        var writer = TrimPathWriter(budget: budget)
        defer { budget = writer.budget }
        var pointIndex = path.points.count
        var needsMove = true, needsClose = false
        for verb in path.verbs.reversed() {
            try writer.budget.consume()
            if needsMove {
                pointIndex -= 1
                try writer.append(.move, points: [path.points[pointIndex]])
                needsMove = false
            }
            pointIndex -= verb.pointCount
            switch verb {
            case .move:
                if needsClose {
                    try writer.append(.close)
                    needsClose = false
                }
                needsMove = true
                // 源reverseAddPath在遇到Move后把游标加回一位，下一轮Move才能使用前一轮廓末点。
                pointIndex += 1
            case .line:
                try writer.append(.line, points: [path.points[pointIndex]])
            case .quad:
                try writer.append(.quad, points: [path.points[pointIndex + 1], path.points[pointIndex]])
            case .conic(let weight):
                try writer.append(.conic(weight: weight), points: [path.points[pointIndex + 1], path.points[pointIndex]])
            case .cubic:
                try writer.append(.cubic, points: [path.points[pointIndex + 2], path.points[pointIndex + 1], path.points[pointIndex]])
            case .close:
                // 闭合边由反向轮廓最后的Close生成，不能现在追加Line改变起点或零段数量。
                needsClose = true
            }
        }
        return try writer.finish()
    }
}
