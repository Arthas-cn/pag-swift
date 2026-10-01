/// 将未裁剪轮廓变为图层坐标原生曲线，不经过Stroke接纳或显示精度折线化。
enum TrimPathConversion {
    /// 已裁剪输入直接共享路径；其他生成器按已有Float组矩阵转换，失败回传已耗预算。
    static func make(_ contour: ShapeContour, budget: inout GeometryBudget) throws -> StrokePath {
        try budget.consume()
        if case .trimmed(let value) = contour { return value.path }
        var writer = TrimPathWriter(budget: budget)
        defer { budget = writer.budget }
        let matrix = try StrokeFloatTransform(contour.matrix)
        switch contour {
        case .path(let path, _):
            try writer.append(path, matrix: matrix, inverse: nil)
        case .rectangle(let rectangle):
            try writer.append(rectangle, matrix: matrix, inverse: nil)
        case .ellipse(let ellipse):
            let conics = try ellipse.conics(budget: &writer.budget)
            try writer.append(.move, points: [matrix.applying(to: conics[0].points[0])])
            for conic in conics {
                try writer.append(.conic(weight: Float(conic.weights[1])), points: [
                    matrix.applying(to: conic.points[1]), matrix.applying(to: conic.points[2])])
            }
            try writer.append(.close)
        case .polyStar(let star):
            let path = try star.path(budget: &writer.budget)
            try writer.append(path, matrix: matrix, inverse: nil)
        case .trimmed:
            throw PAGError.renderingFailure("unexpectedTrimConversion")
        }
        return try writer.finish()
    }
}
