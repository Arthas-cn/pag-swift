import Testing
@testable import pag_swift

/// 凸交集按真实变换保留边界，覆盖重复、反射、相离和预算错误。
struct RenderClipPolygonTests {
    /// 相同裁剪重复加入不会缩小区域或重复生成边；打包边的方向保持正面积。
    @Test func repeatedRectanglesKeepOneBoundary() throws {
        var polygon = RenderClipPolygon(bounds: try RenderBounds(left: 0, top: 0, right: 100, bottom: 100))
        var budget = try GeometryBudget()
        let clip = FrameClip(size: try PAGSize(width: 20, height: 30), matrix: try .translation(x: 10, y: 15))
        for _ in 0..<10 { try polygon.intersect(clip, budget: &budget) }
        #expect(polygon.vertices.count == 4 && abs(area(polygon.vertices) - 600) < 1e-8)
        let edges = try polygon.packedEdges(budget: &budget)
        #expect(edges.count == 4)
        for index in edges.indices {
            let next = edges[(index + 1) % edges.count]
            #expect(edges[index].z == next.x && edges[index].w == next.y)
        }
    }

    /// 两个旋转且含负scale的矩形交集，逐点对照各自逆变换，不用AABB作为预期。
    @Test func rotatedReflectedIntersectionMatchesIndependentLocalChecks() throws {
        var polygon = RenderClipPolygon(bounds: try RenderBounds(left: 0, top: 0, right: 100, bottom: 100))
        var budget = try GeometryBudget()
        let first = FrameClip(size: try PAGSize(width: 60, height: 40),
                              matrix: try SceneAffine.rotation(degrees: 35).following(.translation(x: 30, y: 10)))
        let second = FrameClip(size: try PAGSize(width: 50, height: 60),
                               matrix: try SceneAffine.scale(x: -1, y: 1).following(.rotation(degrees: -17)).following(.translation(x: 80, y: 12)))
        try polygon.intersect(first, budget: &budget)
        try polygon.intersect(second, budget: &budget)
        #expect(polygon.vertices.count > 4 && area(polygon.vertices) > 0)
        for y in stride(from: 0.25, through: 100, by: 2) {
            for x in stride(from: 0.75, through: 100, by: 2) {
                let point = ScenePoint(x: x, y: y)
                let expected = contains(point, clip: first) && contains(point, clip: second)
                #expect(contains(point, vertices: polygon.vertices) == expected)
            }
        }
    }

    /// 相离与仅共享边的裁剪均没有面积，后续更大裁剪不能恢复被清空的区域。
    @Test func emptyAndTouchingIntersectionsStayEmpty() throws {
        var budget = try GeometryBudget()
        for offset in [10.0, 20.0] {
            var polygon = RenderClipPolygon(bounds: try RenderBounds(left: 0, top: 0, right: 10, bottom: 10))
            try polygon.intersect(FrameClip(size: PAGSize(width: 10, height: 10), matrix: .translation(x: offset, y: 0)), budget: &budget)
            try polygon.intersect(FrameClip(size: PAGSize(width: 100, height: 100), matrix: .identity), budget: &budget)
            #expect(polygon.vertices.isEmpty)
        }
    }

    /// 奇异变换与数组预算不足按领域错误结束，不能得到被当成有效区域的半份输出。
    @Test func singularAndOverBudgetClipsFail() throws {
        var polygon = RenderClipPolygon(bounds: try RenderBounds(left: 0, top: 0, right: 10, bottom: 10))
        var budget = try GeometryBudget()
        #expect(throws: PAGError.renderingFailure("metalClipTransform")) {
            try polygon.intersect(FrameClip(size: PAGSize(width: 10, height: 10), matrix: .scale(x: 0, y: 1)), budget: &budget)
        }
        var tiny = try GeometryBudget(maximumBytes: 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) { try polygon.packedEdges(budget: &tiny) }
    }

    /// 独立鞋带公式，用于简单固定范围的面积预期。
    private func area(_ points: [ScenePoint]) -> Double {
        guard points.count > 2 else { return 0 }
        return points.indices.reduce(0) { value, index in
            let next = points[(index + 1) % points.count]
            return value + points[index].x * next.y - points[index].y * next.x
        } * 0.5
    }

    /// 用每个原始矩形的逆矩阵判断点，独立于多边形裁剪实现。
    private func contains(_ point: ScenePoint, clip: FrameClip) -> Bool {
        let m = clip.matrix, x = point.x - clip.matrix.tx, y = point.y - clip.matrix.ty
        let determinant = m.a * m.d - m.b * m.c
        let localX = (m.d * x - m.c * y) / determinant, localY = (-m.b * x + m.a * y) / determinant
        return localX >= 0 && localX <= clip.size.width && localY >= 0 && localY <= clip.size.height
    }

    /// 直接按输出凸边界判断，空输出表示无面积。
    private func contains(_ point: ScenePoint, vertices: [ScenePoint]) -> Bool {
        guard vertices.count >= 3 else { return false }
        return vertices.indices.allSatisfy { index in
            let a = vertices[index], b = vertices[(index + 1) % vertices.count]
            return (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x) >= -1e-9
        }
    }
}
