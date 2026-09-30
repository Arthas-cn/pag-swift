import Testing
@testable import pag_swift

/// 新生成器与完整Fill/Stroke网格链的集成，覆盖虚线起点、轮廓覆盖和失败不发布缓存。
struct ShapeGeneratorGeometryTests {
    /// 四Conic圆形的两单位描边形成完整圆环，Fill中心与Stroke中心的覆盖语义不同。
    @Test func ellipseStrokeProducesRing() throws {
        let contour = try EllipseContour.make(ShapeGeneratorFixtures.ellipse(
            size: .init(constant: ScenePoint(x: 20, y: 20))), at: 0, matrix: .identity)
        let geometry = try stroked([.ellipse(contour)])
        let mesh = try ShapeGeneratorFixtures.mesh(geometry)
        #expect(GeometryTestSupport.coverage(mesh, at: ScenePoint(x: 10.3, y: 0.1)) == 1)
        #expect(GeometryTestSupport.coverage(mesh, at: ScenePoint(x: 8, y: 0.1)) == 0)
        #expect(GeometryTestSupport.coverage(mesh, at: ScenePoint(x: 0.2, y: 0.1)) == 0)
        #expect(GeometryTestSupport.coverage(mesh, at: ScenePoint(x: 12, y: 0.1)) == 0)
        #expect(abs(GeometryTestSupport.area(mesh) - 40 * Double.pi) < 4)
    }

    /// 5画/5空的圆形虚线从顶部向右起步；改变成矩形oval右侧起步会颠倒这两个探针的覆盖。
    @Test func ellipseDashStartsAtTop() throws {
        let contour = try EllipseContour.make(ShapeGeneratorFixtures.ellipse(
            size: .init(constant: ScenePoint(x: 20, y: 20))), at: 0, matrix: .identity)
        let dashes = try #require(try StrokeDashPattern.make(intervals: [5, 5], phase: 0))
        let mesh = try ShapeGeneratorFixtures.mesh(stroked([.ellipse(contour)], dashes: dashes))
        #expect(GeometryTestSupport.coverage(mesh, at: ScenePoint(x: 0.5, y: -10)) == 1)
        #expect(GeometryTestSupport.coverage(mesh, at: ScenePoint(x: 7, y: -7.1)) == 0)
    }

    /// 四点Polygon经真实Fill/Stroke生成菱形，边上描边覆盖一次、中心只属于Fill。
    @Test func polygonUsesCommonFillAndStrokePipeline() throws {
        let contour = try PolyStarContour.make(ShapeGeneratorFixtures.polyStar(kind: .polygon,
            points: .init(constant: 4), outerRadius: .init(constant: 10)), at: 0, matrix: .identity)
        let fill = try ShapeGeneratorFixtures.mesh(ShapeGeometry(contours: [.polyStar(contour)]))
        let stroke = try ShapeGeneratorFixtures.mesh(stroked([.polyStar(contour)]))
        #expect(GeometryTestSupport.coverage(fill, at: ScenePoint(x: 0.2, y: 0.1)) == 1)
        #expect(GeometryTestSupport.coverage(stroke, at: ScenePoint(x: 0.2, y: 0.1)) == 0)
        #expect(GeometryTestSupport.coverage(stroke, at: ScenePoint(x: 5.1, y: 5.1)) == 1)
        #expect(abs(GeometryTestSupport.area(fill) - 200) < 0.001)
    }

    /// 网格生成失败不能新增缓存条目或逐出此前成功结果；恢复后的warm查找仍复用原对象。
    @Test func generationFailureDoesNotPublishCacheEntries() throws {
        let ellipse = try EllipseContour.make(ShapeGeneratorFixtures.ellipse(), at: 0, matrix: .identity)
        let stable = try ShapeGeometry(contours: [.ellipse(ellipse)])
        var cache = try RenderGeometryCache()
        var budget = try GeometryBudget()
        let first = try cache.mesh(for: .shape(stable), transform: .identity, budget: &budget)
        let count = cache.count
        let invalid = try PolyStarContour.make(ShapeGeneratorFixtures.polyStar(
            rotation: .init(constant: Double(Float.greatestFiniteMagnitude))), at: 0, matrix: .identity)
        let candidate = try ShapeGeometry(contours: [.polyStar(invalid)])
        var failing = try GeometryBudget()
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try cache.mesh(for: .shape(candidate), transform: .identity, budget: &failing)
        }
        #expect(cache.count == count)
        var warm = try GeometryBudget(maximumWork: 1)
        #expect(try cache.mesh(for: .shape(stable), transform: .identity, budget: &warm) === first)
    }

    /// 建立共同两单位描边样式；无平台路径、额外画布或替代渲染实现。
    private func stroked(_ contours: [ShapeContour], dashes: StrokeDashPattern? = nil) throws -> ShapeGeometry {
        let style = StrokeStyle(width: 2, cap: .butt, join: .miter, miterLimit: 4, dashes: dashes)
        return try ShapeGeometry(contours: contours, stroke: ShapeStroke(style: style, matrix: .identity))
    }
}
