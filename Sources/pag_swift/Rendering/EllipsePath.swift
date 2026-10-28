/// 固定tgfx/PathKit的Ellipse路径生成；Fill和Stroke共用真实Float Conic，平台路径不参与。
extension EllipseContour {
    /// 从顶部起点按源方向生成四个有理二次段；负/零尺寸保留，预算不足或取消不返回前缀。
    func conics(budget: inout GeometryBudget) throws -> [StrokeConic] {
        try budget.consume(32)
        try budget.reserve(stride: 2048)
        guard [left, top, right, bottom].allSatisfy(\.isFinite) else {
            throw PAGError.resourceLimitExceeded("geometryPrecision")
        }
        // 固定SkRect::centerX/Y各边先减半相加，避免改变Float舍入或让同号大边相加溢出。
        let x = left * 0.5 + right * 0.5, y = top * 0.5 + bottom * 0.5
        let oval = [point(x, top), point(right, y), point(x, bottom), point(left, y)]
        let corners = [point(left, top), point(right, top), point(right, bottom), point(left, bottom)]
        let weight = Double(Float(0.707106781))
        var result: [StrokeConic] = []
        var current = 0
        for _ in 0..<4 {
            try budget.consume()
            let next = (current + (reversed ? 3 : 1)) % 4
            let corner = reversed ? current : next
            result.append(StrokeConic(points: [oval[current], corners[corner], oval[next]], weights: [1, weight, 1]))
            current = next
        }
        return result
    }

    /// 将已经按源Float计算的点提升为几何纯值，不在此处施加描边坐标幅度上限。
    private func point(_ x: Float, _ y: Float) -> ScenePoint { ScenePoint(x: Double(x), y: Double(y)) }
}

/// Ellipse仅在普通Fill消费时转换/细分，保留完整误差预算，不改变Stroke中心线。
extension PathFlattening {
    /// 两个近似阶段各使用一半局部容差；组矩阵由调用者在输出后应用一次。
    static func ellipse(_ contour: EllipseContour, tolerance: Double,
                        budget: inout GeometryBudget) throws -> [[ScenePoint]] {
        let half = tolerance * 0.5
        guard half.isFinite, half > 0 else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        var builder = FlattenedPathBuilder(budget: budget, tolerance: half)
        defer { budget = builder.budget }
        for conic in try contour.conics(budget: &builder.budget) {
            if builder.current.isEmpty { try builder.append(conic.points[0]) }
            let cubics = try StrokeConicApproximation.cubics(conic, tolerance: half, transform: .identity,
                                                           budget: &builder.budget)
            for cubic in cubics {
                try builder.budget.consume()
                try builder.curve(first: cubic.first, second: cubic.second, end: cubic.end)
            }
        }
        try builder.finishContour()
        return builder.contours
    }
}
