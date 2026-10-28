import CoreGraphics
import Testing
@testable import pag_swift

/// 复合路径填充的孔洞、重叠、自交和数值边界，不把单轮廓独立覆盖当作 nonzero。
struct NonzeroTessellationTests {
    /// 同向嵌套填满、反向嵌套挖洞，第三层再形成岛；重复覆盖只计一次。
    @Test func nestedWindingPreservesHolesAndIslands() throws {
        let outer = GeometryTestSupport.rectangle(0, 0, 10, 10)
        let inner = GeometryTestSupport.rectangle(2, 2, 6, 6)
        let island = GeometryTestSupport.rectangle(4, 4, 2, 2)
        let filled = try GeometryTestSupport.mesh([outer, inner])
        let hole = try GeometryTestSupport.mesh([outer, inner.reversed()])
        let nested = try GeometryTestSupport.mesh([outer, inner.reversed(), island])
        #expect(GeometryTestSupport.area(filled) == 100)
        #expect(GeometryTestSupport.area(hole) == 64)
        #expect(GeometryTestSupport.area(nested) == 68)
        #expect(GeometryTestSupport.coverage(hole, at: ScenePoint(x: 3.13, y: 3.71)) == 0)
        #expect(GeometryTestSupport.coverage(nested, at: ScenePoint(x: 4.23, y: 4.81)) == 1)
    }

    /// 部分重叠同向轮廓求 union，反向时只挖去相交部分；相同反向轮廓完全抵消。
    @Test func overlapsAndCoincidentEdgesBlendOnlyOnce() throws {
        let left = GeometryTestSupport.rectangle(0, 0, 10, 10)
        let right = GeometryTestSupport.rectangle(5, 5, 10, 10)
        let union = try GeometryTestSupport.mesh([left, right])
        let difference = try GeometryTestSupport.mesh([left, right.reversed()])
        let cancelled = try GeometryTestSupport.mesh([left, left.reversed()])
        #expect(GeometryTestSupport.area(union) == 175)
        #expect(GeometryTestSupport.area(difference) == 150)
        #expect(cancelled.vertices.isEmpty)
        #expect(GeometryTestSupport.coverage(union, at: ScenePoint(x: 7.31, y: 8.79)) == 1)
        #expect(GeometryTestSupport.coverage(difference, at: ScenePoint(x: 7.31, y: 8.79)) == 0)
    }

    /// 蝴蝶结中间交点必须切开扫描带，两瓣合计面积 50，反转整个路径不改变填充。
    @Test func selfIntersectionSplitsBandsAtCrossings() throws {
        let points = [ScenePoint(x: 0, y: 0), ScenePoint(x: 10, y: 10),
                      ScenePoint(x: 0, y: 10), ScenePoint(x: 10, y: 0)]
        let forward = try GeometryTestSupport.mesh([points])
        let backward = try GeometryTestSupport.mesh([points.reversed()])
        #expect(GeometryTestSupport.area(forward) == 50 && GeometryTestSupport.area(backward) == 50)
        #expect(GeometryTestSupport.coverage(forward, at: ScenePoint(x: 5.31, y: 2.11)) == 1)
        #expect(GeometryTestSupport.coverage(forward, at: ScenePoint(x: 1.31, y: 5.11)) == 0)
    }

    /// 多于 255 层同向路径仍有覆盖，绕数不能像 8 位 stencil 一样溢出清零。
    @Test func windingDoesNotWrapAtEightBits() throws {
        let rectangle = GeometryTestSupport.rectangle(0, 0, 10, 10)
        let mesh = try GeometryTestSupport.mesh(Array(repeating: rectangle, count: 256))
        #expect(GeometryTestSupport.area(mesh) == 100 && mesh.vertices.count == 6)
    }

    /// 共享顶点、水平边、重复终点与零面积轮廓不引入裂缝或伪三角形。
    @Test func touchingAndDegenerateContoursRemainWellDefined() throws {
        let left = GeometryTestSupport.rectangle(0, 0, 5, 5)
        let right = GeometryTestSupport.rectangle(5, 5, 5, 5)
        let line = [ScenePoint(x: 1, y: 1), ScenePoint(x: 2, y: 2), ScenePoint(x: 3, y: 3)]
        let mesh = try GeometryTestSupport.mesh([left + [left[0]], right, line, []])
        #expect(GeometryTestSupport.area(mesh) == 50)
        #expect(try GeometryTestSupport.mesh([line]).vertices.isEmpty)
        #expect(try GeometryTestSupport.mesh([]).vertices.isEmpty)
    }

    /// 先消去巨大共同平移，窄矩形的网格顶点仍保留本地尺寸，避免上传 Float 时先丢精度。
    @Test func localOriginPreservesSmallTranslatedGeometry() throws {
        let offset = Double(1 << 40)
        let mesh = try GeometryTestSupport.mesh([GeometryTestSupport.rectangle(offset, -offset, 3, 7)])
        #expect(mesh.origin == ScenePoint(x: offset, y: -offset))
        #expect(mesh.vertices.allSatisfy { $0.x >= 0 && $0.x <= 3 && $0.y >= 0 && $0.y <= 7 })
        #expect(GeometryTestSupport.area(mesh) == 21)
    }

    /// 相邻 Double 高度之间没有可表示中点时仍保留薄带，不将非零面积直接丢弃。
    @Test func adjacentFloatingPointLevelsDoNotRequireRepresentableMidpoint() throws {
        let base = GeometryTestSupport.rectangle(0, 0, 2, 1)
        let next = GeometryTestSupport.rectangle(0, 1, 1, 1.0.nextUp - 1)
        let mesh = try GeometryTestSupport.mesh([base, next])
        #expect(mesh.vertices.contains { $0.y == 1.0.nextUp })
        #expect(mesh.vertices.filter { $0.y == 1.0.nextUp }.count == 3)
    }

    /// 用包含交叉与部分共线边的固定复合路径逐点对照系统 nonzero，所有内部点最多覆盖一次。
    @Test func compoundCoverageMatchesIndependentSystemFill() throws {
        let contours = [
            [ScenePoint(x: 0, y: 0), ScenePoint(x: 17, y: 11), ScenePoint(x: 2, y: 17),
             ScenePoint(x: 11, y: -3), ScenePoint(x: 13, y: 19)],
            GeometryTestSupport.rectangle(3, 2, 8, 10, reversed: true),
            [ScenePoint(x: 1, y: 1), ScenePoint(x: 13, y: 13), ScenePoint(x: 12, y: 1)]
        ]
        let mesh = try GeometryTestSupport.mesh(contours)
        let path = GeometryTestSupport.systemPath(GeometryTestSupport.outline(contours))
        var mismatches = 0
        var overlaps = 0
        for y in -4..<20 {
            for x in -1..<18 {
                let point = ScenePoint(x: Double(x) + 0.371, y: Double(y) + 0.619)
                let coverage = GeometryTestSupport.coverage(mesh, at: point)
                if (coverage > 0) != path.contains(CGPoint(x: point.x, y: point.y), using: .winding) { mismatches += 1 }
                if coverage > 1 { overlaps += 1 }
            }
        }
        #expect(mismatches == 0 && overlaps == 0)
    }

    /// 非有限输入、字节上限和工作上限分别失败，不能返回已经生成的部分轮廓。
    @Test func invalidGeometryAndBothBudgetsFailExplicitly() throws {
        let contour = GeometryTestSupport.rectangle(0, 0, 10, 10)
        var bytes = try GeometryBudget(maximumBytes: 16)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try NonzeroTessellation.prepare([contour], budget: &bytes)
        }
        var work = try GeometryBudget(maximumWork: 4)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try NonzeroTessellation.prepare([contour], budget: &work)
        }
        #expect(throws: PAGError.renderingFailure("geometryNonFinite")) {
            try GeometryTestSupport.mesh([[ScenePoint(x: .infinity, y: 0)]])
        }
    }
}
