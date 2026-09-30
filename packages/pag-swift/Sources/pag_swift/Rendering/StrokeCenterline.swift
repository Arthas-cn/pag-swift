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

/// 按固定SkPath::addRRect/addOval/addRect的startIndex2构造矩形中心线，不借用fill的任意起点。
extension StrokePathBuilder {
    /// 保留矩形、普通圆角与oval各自的起点和方向，所有端点先经两次源Float变换。
    mutating func append(_ rectangle: RoundedRectangleContour, matrix: StrokeFloatTransform,
                         inverse: StrokeFloatTransform?) throws {
        let left = Float(rectangle.left), right = Float(rectangle.right)
        let top = Float(rectangle.top), bottom = Float(rectangle.bottom), radius = Float(rectangle.radius)
        try budget.reserve(24, stride: 32)
        let corners = try [point(left, top), point(right, top), point(right, bottom), point(left, bottom)].map {
            try mapped($0, matrix: matrix, inverse: inverse)
        }
        if radius == 0 {
            let indices = rectangle.reversed ? [1, 0, 3, 2] : [1, 2, 3, 0]
            try append(.move, points: [corners[indices[0]]])
            for index in indices.dropFirst() { try append(.line, points: [corners[index]]) }
            try append(.close)
            return
        }
        if radius >= (right - left) * 0.5, radius >= (bottom - top) * 0.5 {
            // SkRect::centerX/Y先各自减半再相加，不能先把两条大边相加后除二。
            let x = left * 0.5 + right * 0.5, y = top * 0.5 + bottom * 0.5
            let oval = try [point(x, top), point(right, y), point(x, bottom), point(left, y)].map {
                try mapped($0, matrix: matrix, inverse: inverse)
            }
            try append(.move, points: [oval[1]])
            var current = 1
            for _ in 0..<4 {
                let next = (current + (rectangle.reversed ? 3 : 1)) % 4
                let corner = rectangle.reversed ? current : next
                try append(.conic(weight: Float(0.707106781)), points: [corners[corner], oval[next]])
                current = next
            }
            try append(.close)
            return
        }
        let raw = [point(left + radius, top), point(right - radius, top), point(right, top + radius),
                   point(right, bottom - radius), point(right - radius, bottom), point(left + radius, bottom),
                   point(left, bottom - radius), point(left, top + radius)]
        let rounded = try raw.map { try mapped($0, matrix: matrix, inverse: inverse) }
        try append(.move, points: [rounded[2]])
        var current = 2
        if rectangle.reversed {
            for (index, corner) in [1, 0, 3, 2].enumerated() {
                let next = (current + 7) % 8
                try append(.conic(weight: Float(0.707106781)), points: [corners[corner], rounded[next]])
                current = next
                // 逆向最后一条边由Close补齐；提前额外Line会改变退化与dash输入结构。
                if index < 3 {
                    current = (current + 7) % 8
                    try append(.line, points: [rounded[current]])
                }
            }
        } else {
            for corner in [2, 3, 0, 1] {
                current = (current + 1) % 8
                try append(.line, points: [rounded[current]])
                let next = (current + 1) % 8
                try append(.conic(weight: Float(0.707106781)), points: [corners[corner], rounded[next]])
                current = next
            }
        }
        try append(.close)
    }

    /// 将已完成源Float计算的点提升为纯值，调用方随后验证坐标幅度。
    private func point(_ x: Float, _ y: Float) -> ScenePoint { ScenePoint(x: Double(x), y: Double(y)) }
}
