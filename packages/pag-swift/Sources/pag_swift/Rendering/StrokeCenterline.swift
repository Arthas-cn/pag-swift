/// 将当前paint累计中心线转换到描边坐标；保留源次序与退化轮廓，不创建CG对象。
enum StrokeCenterline {
    /// 完整生成规范化临时路径，圆角保留Conic供测量和描边；失败不返回部分路径。
    static func make(_ geometry: ShapeGeometry, limits: StrokeBackendLimits = .standard,
                     budget: inout GeometryBudget) throws -> StrokePath {
        guard let stroke = geometry.stroke else { throw PAGError.invalidArgument("missingShapeStroke") }
        var builder = StrokePathBuilder(budget: budget, limits: limits)
        defer { budget = builder.budget }
        let inverse = try stroke.inverse.map(StrokeFloatTransform.init)
        for contour in geometry.contours {
            try builder.budget.consume()
            let matrix = try StrokeFloatTransform(contour.matrix)
            switch contour {
            case .trimmed(let value):
                try builder.append(value.path, inverse: inverse)
            case .path(let path, _):
                try builder.append(path, matrix: matrix, inverse: inverse)
            case .rectangle(let rectangle):
                try builder.append(rectangle, matrix: matrix, inverse: inverse)
            case .ellipse(let ellipse):
                // 保留原四Conic和顶部起点给dash测量，不能使用普通Fill的三次近似。
                let conics = try ellipse.conics(budget: &builder.budget)
                try builder.append(.move, points: [builder.mapped(conics[0].points[0], matrix: matrix, inverse: inverse)])
                for conic in conics {
                    try builder.append(.conic(weight: Float(conic.weights[1])), points: [
                        builder.mapped(conic.points[1], matrix: matrix, inverse: inverse),
                        builder.mapped(conic.points[2], matrix: matrix, inverse: inverse)])
                }
                try builder.append(.close)
            case .polyStar(let polyStar):
                let path = try polyStar.path(budget: &builder.budget)
                try builder.append(path, matrix: matrix, inverse: inverse)
            }
        }
        if stroke.style.dashes != nil { try builder.prepareZeroLineForDashing() }
        return try builder.finish()
    }
}
