import CoreGraphics
import Testing
@testable import pag_swift

/// 有界边候选和活动扫描的行为验收；解析区域和系统nonzero作为独立参照。
struct NonzeroSweepTests {
    /// 两轴分别放置2048个互不接触矩形；有限小work预算排除旧全边对与逐带历史扫描。
    @Test(arguments: [true, false])
    func separatedContoursAvoidQuadraticScanning(_ horizontal: Bool) throws {
        let contours = (0..<2_048).map { index in
            GeometryTestSupport.rectangle(horizontal ? Double(index) * 3 : 0,
                                          horizontal ? 0 : Double(index) * 3, 2, 2)
        }
        var budget = try GeometryBudget(maximumWork: 500_000)
        let mesh = try NonzeroTessellation.prepare(contours, budget: &budget)
        #expect(GeometryTestSupport.area(mesh) == 8_192 && mesh.vertices.count == 12_288)
        #expect(budget.work < 500_000)
        for index in [0, 1_024, 2_047] {
            let inside = ScenePoint(x: horizontal ? Double(index) * 3 + 0.3 : 0.3,
                                    y: horizontal ? 1.2 : Double(index) * 3 + 1.2)
            let gap = ScenePoint(x: horizontal ? Double(index) * 3 + 2.3 : 0.3,
                                 y: horizontal ? 1.2 : Double(index) * 3 + 2.3)
            #expect(GeometryTestSupport.coverage(mesh, at: inside) == 1)
            #expect(GeometryTestSupport.coverage(mesh, at: gap) == 0)
        }
    }

    /// 零宽竖边穿过斜边时必须保留真正内部交点；宽/高/等长轴选择及反向轮廓均对照独立填充。
    @Test(arguments: [ScenePoint(x: 2, y: 1), ScenePoint(x: 1, y: 3), ScenePoint(x: 1, y: 2)])
    func verticalCrossingsSurviveEitherProjectionAxis(_ scale: ScenePoint) throws {
        let original = [ScenePoint(x: 0, y: 0), ScenePoint(x: 0, y: 10),
                        ScenePoint(x: 10, y: 0), ScenePoint(x: -10, y: 10)]
        let contour = original.map { ScenePoint(x: $0.x * scale.x, y: $0.y * scale.y) }
        let hole = GeometryTestSupport.rectangle(-2 * scale.x, 2 * scale.y, 4 * scale.x, 6 * scale.y, reversed: true)
        for contours in [[contour, hole], [Array(contour.reversed()), hole]] {
            let mesh = try GeometryTestSupport.mesh(contours)
            let reference = GeometryTestSupport.systemPath(GeometryTestSupport.outline(contours))
            for y in 0..<10 {
                for x in -10..<10 {
                    let point = ScenePoint(x: (Double(x) + 0.371) * scale.x, y: (Double(y) + 0.619) * scale.y)
                    let expected = reference.contains(CGPoint(x: point.x, y: point.y), using: .winding)
                    #expect(GeometryTestSupport.coverage(mesh, at: point) == (expected ? 1 : 0))
                }
            }
        }
    }

    /// 等投影端点、共享边和反向孔洞共同出现时，活动边不能提前退出或产生重复覆盖。
    @Test func equalProjectionsAndSharedEndpointsKeepWinding() throws {
        let left = GeometryTestSupport.rectangle(0, 0, 10, 10)
        let right = GeometryTestSupport.rectangle(10, 0, 10, 10)
        let hole = GeometryTestSupport.rectangle(5, 2, 10, 6, reversed: true)
        let mesh = try GeometryTestSupport.mesh([left, right, hole])
        #expect(GeometryTestSupport.area(mesh) == 140)
        #expect(GeometryTestSupport.coverage(mesh, at: ScenePoint(x: 10.3, y: 4.1)) == 0)
        #expect(GeometryTestSupport.coverage(mesh, at: ScenePoint(x: 10.3, y: 1.1)) == 1)
        let thin = GeometryTestSupport.rectangle(10, 10, 2, 10.0.nextUp - 10)
        let extended = try GeometryTestSupport.mesh([left, right, hole, thin])
        #expect(extended.vertices.contains { $0.y == 10.0.nextUp })
    }

    /// 密集真实交叉仍可能是二次工作；达到原限额必须失败，不能因存在投影索引就绕过预算。
    @Test func denseCrossingsStillRespectWorkLimit() throws {
        let contours = (0..<128).map { index in
            let offset = Double(index) / 8
            return [ScenePoint(x: offset, y: 0), ScenePoint(x: 128 - offset, y: 100),
                    ScenePoint(x: offset + 0.25, y: 100), ScenePoint(x: 128 - offset + 0.25, y: 0)]
        }
        var budget = try GeometryBudget(maximumWork: 20_000)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try NonzeroTessellation.prepare(contours, budget: &budget)
        }
        #expect(budget.work <= 20_000 && budget.work > 1_000)
    }

    /// 新索引和活动数组必须计入字节限制；预取消继续抛专用错误，不发布部分扫描结果。
    @Test func projectionStorageAndCancellationRemainBounded() async throws {
        let contour = GeometryTestSupport.rectangle(0, 0, 10, 10)
        var budget = try GeometryBudget(maximumBytes: 350)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try NonzeroTessellation.prepare([contour], budget: &budget)
        }
        let task = Task {
            var budget = try GeometryBudget()
            withUnsafeCurrentTask { $0?.cancel() }
            return try NonzeroTessellation.prepare([contour], budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
