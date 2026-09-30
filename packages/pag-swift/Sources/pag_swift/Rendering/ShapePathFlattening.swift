/// PAG源路径进入既有曲线细分器的适配；几何游标遵守固定TGFX/PathKit，不复用压缩字段的lastPoint。
extension PathFlattening {
    /// 将完整源路径变为按绕序排列的复合折线；开放轮廓隐式闭合，无面积轮廓省略，错误不截断输出。
    static func sourcePath(_ path: SourcePath, tolerance: Double,
                           budget: inout GeometryBudget) throws -> [[ScenePoint]] {
        guard tolerance.isFinite, tolerance > 0 else { throw PAGError.invalidArgument("geometryTolerance") }
        var builder = FlattenedPathBuilder(budget: budget, tolerance: tolerance)
        defer { budget = builder.budget }
        var index = 0
        for verb in path.verbs {
            try builder.budget.consume()
            switch verb {
            case .move:
                try builder.finishContour()
                try builder.append(path.points[index])
            case .line:
                // SkPath::injectMoveToIfNeeded在没有Move的初始路径中补原点；close后已保留最近起点。
                if builder.current.isEmpty { try builder.append(.zero) }
                try builder.append(path.points[index])
            case .cubic:
                if builder.current.isEmpty { try builder.append(.zero) }
                try builder.curve(first: path.points[index], second: path.points[index + 1], end: path.points[index + 2])
            case .close:
                if let start = builder.current.first {
                    // 重复close只留下单个待用起点，不产生新轮廓；随后的line/cubic从该起点继续。
                    try builder.finishContour()
                    try builder.append(start)
                }
            }
            index += verb.pointCount
        }
        try builder.finishContour()
        try Task.checkCancellation()
        return builder.contours
    }
}
