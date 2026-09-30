import Foundation
import Testing
@testable import pag_swift

/// 用独立圆和线段距离判据验证Round适配的放大精度及复杂nonzero组合，不调用系统stroke计算期望。
struct StrokeRoundGeometryTests {
    /// 短边的外侧扇区不能变成完整圆盘，否则会越过相邻Butt端点并扩大内侧区域。
    @Test func shortButtLegsOnlyGainOuterSector() throws {
        let source = try path([p(0, 0), p(0.1, 0), p(0.1, 0.1)])
        let mesh = try mesh(source, cap: .butt)
        #expect(GeometryTestSupport.coverage(mesh, at: p(-1, -1)) == 0)
        #expect(GeometryTestSupport.coverage(mesh, at: p(1.3, -1.2)) == 1)
        #expect(GeometryTestSupport.coverage(mesh, at: p(1.8, -1.8)) == 0)
        #expect(GeometryTestSupport.coverage(mesh, at: p(-1, 0.05)) == 1)
    }

    /// 顺逆向闭合矩形都保留中心孔洞，四角圆弧与主体只覆盖一次。
    @Test func closedRectangleRetainsHoleInBothDirections() throws {
        let points = [p(0, 0), p(10, 0), p(10, 10), p(0, 10)]
        for reversed in [false, true] {
            let mesh = try mesh(path(reversed ? points.reversed() : points, closed: true))
            #expect(abs(GeometryTestSupport.area(mesh) - (144 + 4 * Double.pi)) < 0.03)
            #expect(GeometryTestSupport.coverage(mesh, at: p(5.1, 5.3)) == 0)
            #expect(GeometryTestSupport.coverage(mesh, at: p(5.1, 0.3)) == 1)
            #expect(GeometryTestSupport.coverage(mesh, at: p(-1.2, -1.3)) == 1)
        }
    }

    /// 自交折线按各线段半径邻域的并集比较，换向不能产生抵消孔洞或双重alpha区域。
    @Test func crossingContoursMatchSegmentDistanceUnion() throws {
        let points = [p(0, 0), p(10, 10), p(0, 10), p(10, 0)]
        for reversed in [false, true] {
            let mesh = try mesh(path(reversed ? points.reversed() : points, closed: true))
            for x in -4...24 {
                for y in -4...24 {
                    let point = p(Double(x) * 0.5 + 0.173, Double(y) * 0.5 + 0.419)
                    let distance = points.indices.map { index in
                        distance(point, from: points[index], to: points[(index + 1) % points.count])
                    }.min()!
                    // 覆盖测试避开0.001折线近似的边界带，期望仍来自独立线段距离。
                    if abs(distance - 2) < 0.005 { continue }
                    #expect(GeometryTestSupport.coverage(mesh, at: point) == (distance < 2 ? 1 : 0),
                            "reversed=\(reversed) point=\(point) distance=\(distance)")
                }
            }
        }
    }

    /// 十万倍放大端帽相对源Float conic保持0.01误差；源构造与理想圆的偏差单独检查。
    @Test func enlargedRoundCapsKeepSourceConicAccuracy() throws {
        let matrix = try SceneAffine(a: 100_000, b: 0, c: 0, d: 100_000, tx: 17, ty: 23)
        for end in [p(10, 0), p(6, 8)] {
            var budget = try GeometryBudget()
            let result = try StrokeOutline.make(path([.zero, end]), style: style(cap: .round),
                restoration: matrix, tolerance: 0.01, budget: &budget)
            let centers = [p(17, 23), p(end.x * 100_000 + 17, end.y * 100_000 + 23)]
            let reference = sourceCaps(end: end)
            var current = ScenePoint.zero
            var index = 0
            var cubicCount = 0
            for verb in result.verbs {
                switch verb {
                case .move, .line: current = result.points[index]
                case .cubic:
                    let a = result.points[index], b = result.points[index + 1], c = result.points[index + 2]
                    for step in 0...16 {
                        let t = Double(step) / 16, u = 1 - t
                        let sample = p(u * u * u * current.x + 3 * u * u * t * a.x + 3 * u * t * t * b.x + t * t * t * c.x,
                                       u * u * u * current.y + 3 * u * u * t * a.y + 3 * u * t * t * b.y + t * t * t * c.y)
                        let radial = centers.map { hypot(sample.x - $0.x, sample.y - $0.y) }.min()!
                        // Float控制点在十万倍下有可见ULP偏差，不能把它归因于Double conic转换。
                        #expect(abs(radial - 200_000) <= 0.15)
                        #expect(reference.map { sourceDistance(sample, curve: $0) }.min()! <= 0.010001)
                    }
                    current = c
                    cubicCount += 1
                case .close: break
                }
                index += verb.pointCount
            }
            #expect(cubicCount > 4)
        }
    }

    /// 两条测试直线的法线分别为(0,-1)和(4/5,-3/5)，独立生成源Float两段端帽参照。
    private func sourceCaps(end: ScenePoint) -> [[ScenePoint]] {
        let normal: SIMD2<Float> = end.y == 0 ? SIMD2(0, -2) : SIMD2(Float(4.0 / 5) * 2, Float(-3.0 / 5) * 2)
        let end = SIMD2(Float(end.x), Float(end.y))
        return [(SIMD2<Float>.zero, -normal), (end, normal)].flatMap { pivot, normal in
            let projected = pivot + SIMD2(-normal.y, normal.x)
            return [[pivot + normal, projected + normal, projected], [projected, projected - normal, pivot - normal]].map { points in
                points.map { p(Double($0.x) * 100_000 + 17, Double($0.y) * 100_000 + 23) }
            }
        }
    }

    /// 单个四分圆conic的最近距离以独立有理公式和有界三分搜索求得，不调用生产转换器。
    private func sourceDistance(_ point: ScenePoint, curve: [ScenePoint]) -> Double {
        let weight = Double(Float(0.707106781))
        /// 独立有理二次曲线上的指定参数到目标点的欧氏距离。
        func distance(_ t: Double) -> Double {
            let u = 1 - t, middle = 2 * weight * t * u, denominator = u * u + middle + t * t
            let x = (u * u * curve[0].x + middle * curve[1].x + t * t * curve[2].x) / denominator
            let y = (u * u * curve[0].y + middle * curve[1].y + t * t * curve[2].y) / denominator
            return hypot(point.x - x, point.y - y)
        }
        var low = 0.0, high = 1.0
        for _ in 0..<64 {
            let a = low + (high - low) / 3, b = high - (high - low) / 3
            if distance(a) < distance(b) { high = b } else { low = a }
        }
        return min(distance(0), distance(1), distance((low + high) * 0.5))
    }

    /// 生成纯语义折线，不构造自称合法的PAG字节。
    private func path(_ points: [ScenePoint], closed: Bool = false) throws -> StrokePath {
        try strokePath(verbs: [.move] + Array(repeating: .line, count: points.count - 1) + (closed ? [.close] : []), points: points)
    }

    /// 半宽为2，接角恒为Round，以便独立解析圆弧区域。
    private func style(cap: SourceLineCap) -> StrokeStyle {
        StrokeStyle(width: 4, cap: cap, join: .round, miterLimit: 4, dashes: nil)
    }

    /// 通过真实轮廓、折线化和nonzero网格，验证Swift边界组合的最终区域。
    private func mesh(_ source: StrokePath, cap: SourceLineCap = .round) throws -> RenderMesh {
        var budget = try GeometryBudget()
        let result = try StrokeOutline.make(source, style: style(cap: cap), tolerance: 0.0005, budget: &budget)
        return try GeometryTestSupport.mesh(PathFlattening.sourcePath(result, tolerance: 0.001, budget: &budget))
    }

    /// 线段最近点距离独立于生产几何算法，退化输入按点计算。
    private func distance(_ point: ScenePoint, from start: ScenePoint, to end: ScenePoint) -> Double {
        let x = end.x - start.x, y = end.y - start.y
        let squared = x * x + y * y
        let t = squared == 0 ? 0 : max(0, min(1, ((point.x - start.x) * x + (point.y - start.y) * y) / squared))
        return hypot(point.x - (start.x + t * x), point.y - (start.y + t * y))
    }

    /// 简写测试中的解析坐标，保留Double计算。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }
    /// 用独立准备预算发布规范化描边输入，不给生产入口添加旧SourcePath兼容桥。
    private func strokePath(verbs: [StrokePathVerb], points: [ScenePoint]) throws -> StrokePath {
        var budget = try GeometryBudget()
        return try StrokePath(verbs: verbs, points: points, budget: &budget)
    }

}
