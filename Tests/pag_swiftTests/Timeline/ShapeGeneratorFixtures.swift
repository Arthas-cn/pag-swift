import Testing
@testable import pag_swift

/// 新生成器的纯语义夹具；不给生产库增加测试专用初始化器，也不合成PAG字节。
enum ShapeGeneratorFixtures {
    /// 默认20×10椭圆，调用者可逐字段替换轨道或方向。
    static func ellipse(reversed: Bool = false,
                        size: SourceProperty<ScenePoint> = .init(constant: ScenePoint(x: 20, y: 10)),
                        position: SourceProperty<ScenePoint> = .init(constant: .zero)) -> SourceEllipse {
        SourceEllipse(reversed: reversed, size: size, position: position)
    }

    /// 默认以90度旋转为基准的分数星形，首角仍受小数部分调整，内外半径1/2便于独立检验。
    static func polyStar(kind: SourcePolyStarKind = .star, reversed: Bool = false,
                         points: SourceProperty<Double> = .init(constant: 2.5),
                         position: SourceProperty<ScenePoint> = .init(constant: .zero),
                         rotation: SourceProperty<Double> = .init(constant: 90),
                         innerRadius: SourceProperty<Double> = .init(constant: 1),
                         outerRadius: SourceProperty<Double> = .init(constant: 2),
                         innerRoundness: SourceProperty<Double> = .init(constant: 0),
                         outerRoundness: SourceProperty<Double> = .init(constant: 0)) -> SourcePolyStar {
        SourcePolyStar(kind: kind, reversed: reversed, points: points, position: position, rotation: rotation,
            innerRadius: innerRadius, outerRadius: outerRadius, innerRoundness: innerRoundness, outerRoundness: outerRoundness)
    }

    /// 独立预算生成完整源路径，供精确Float常量断言；不会调用正式文件入口。
    static func path(_ source: SourcePolyStar) throws -> SourcePath {
        let contour = try PolyStarContour.make(source, at: 0, matrix: .identity)
        var budget = try GeometryBudget()
        return try contour.path(budget: &budget)
    }

    /// 默认无dash的二单位描边，保留所有中心线拓扑供测试观察。
    static func centerline(_ contours: [ShapeContour], dashes: StrokeDashPattern? = nil,
                           paint: SceneAffine = .identity) throws -> StrokePath {
        let style = StrokeStyle(width: 2, cap: .butt, join: .miter, miterLimit: 4, dashes: dashes)
        let geometry = try ShapeGeometry(contours: contours, stroke: ShapeStroke(style: style, matrix: paint))
        var budget = try GeometryBudget()
        return try StrokeCenterline.make(geometry, budget: &budget)
    }

    /// 使用真实nonzero几何缓存准备网格，提供面积和覆盖检查所需的完整结果。
    static func mesh(_ geometry: ShapeGeometry) throws -> RenderMesh {
        var cache = try RenderGeometryCache()
        var budget = try GeometryBudget()
        return try cache.mesh(for: .shape(geometry), transform: .identity, budget: &budget)
    }
}
