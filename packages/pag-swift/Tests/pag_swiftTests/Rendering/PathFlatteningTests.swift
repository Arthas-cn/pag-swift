import Foundation
import Testing
@testable import pag_swift

/// 曲线细分的显示精度、源路径顺序与有界失败；不把解析圆角替换为固定四段 cubic。
struct PathFlatteningTests {
    /// 最大奇异值包含斜切与两轴方向，平移与纯旋转不增加精度，向上归档保守覆盖缩放。
    @Test func precisionUsesStretchAndIgnoresTranslation() throws {
        let identity = try GeometryPrecision(transform: .identity)
        let translation = try GeometryPrecision(transform: .translation(x: 1e12, y: -1e12))
        let scale = try GeometryPrecision(transform: .scale(x: 2.01, y: -0.1))
        let shear = try SceneAffine(a: 1, b: 0, c: 1, d: 1, tx: 0, ty: 0)
        #expect(identity == translation && identity.exponent == 0)
        #expect(scale.exponent == 2 && scale.tolerance == 0.03125)
        #expect(abs(try GeometryPrecision.maximumStretch(shear) - (1 + sqrt(5)) * 0.5) < 1e-14)
        #expect(try GeometryPrecision(transform: shear).exponent == 1)
        #expect(try GeometryPrecision(transform: .scale(x: 0.01, y: 0.01)) == identity)
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try GeometryPrecision(transform: .scale(x: Double.greatestFiniteMagnitude, y: 1))
        }
    }

    /// 二次/三次曲线逐参数采样到输出折线的距离不超过容差，缩紧容差增加分段。
    @Test func adaptiveCurvesRespectSegmentDistanceBound() throws {
        let start = ScenePoint(x: 0, y: 0), first = ScenePoint(x: -20, y: 80)
        let second = ScenePoint(x: 110, y: -70), end = ScenePoint(x: 100, y: 10)
        for cubic in [false, true] {
            let outline = GlyphOutline(elements: [.move(start), cubic ? .cubic(first: first, second: second, end: end)
                                                    : .quadratic(control: first, end: end), .line(start), .close])
            var fineBudget = try GeometryBudget(), coarseBudget = try GeometryBudget()
            let fine = try #require(PathFlattening.glyph(outline, tolerance: 0.03125, budget: &fineBudget).first)
            let coarse = try #require(PathFlattening.glyph(outline, tolerance: 0.5, budget: &coarseBudget).first)
            #expect(fine.count > coarse.count)
            var maximumDistance = 0.0
            for sample in 0...1000 {
                let t = Double(sample) / 1000, s = 1 - t
                let point = cubic
                    ? ScenePoint(x: s * s * s * start.x + 3 * s * s * t * first.x + 3 * s * t * t * second.x + t * t * t * end.x,
                                 y: s * s * s * start.y + 3 * s * s * t * first.y + 3 * s * t * t * second.y + t * t * t * end.y)
                    : ScenePoint(x: s * s * start.x + 2 * s * t * first.x + t * t * end.x,
                                 y: s * s * start.y + 2 * s * t * first.y + t * t * end.y)
                var distance = Double.infinity
                for index in 1..<fine.count {
                    distance = min(distance, try GeometryMath.distance(point, to: fine[index - 1], fine[index]))
                }
                maximumDistance = max(maximumDistance, distance)
            }
            #expect(maximumDistance <= 0.03125)
        }
    }

    /// 共线控制点可能让曲线超出端点区间；使用弦段距离保留回折，闭合环也不能直接消掉。
    @Test func collinearOvershootAndClosedLoopAreNotDropped() throws {
        let overshoot = GlyphOutline(elements: [.move(.zero), .quadratic(control: ScenePoint(x: 100, y: 0),
                                                                      end: ScenePoint(x: 1, y: 0)),
                                                .line(ScenePoint(x: 1, y: 10)), .close])
        var budget = try GeometryBudget()
        let points = try #require(PathFlattening.glyph(overshoot, tolerance: 0.125, budget: &budget).first)
        #expect(try #require(points.map(\.x).max()) > 50)
        let loop = GlyphOutline(elements: [.move(.zero), .cubic(first: ScenePoint(x: 50, y: 80),
                                                              second: ScenePoint(x: -50, y: 80), end: .zero), .close])
        var loopBudget = try GeometryBudget()
        let contour = try #require(PathFlattening.glyph(loop, tolerance: 0.125, budget: &loopBudget).first)
        #expect(contour.count > 10)
        #expect(try GeometryTestSupport.mesh([contour]).vertices.count > 0)
    }

    /// close 之后当前点回到起点，后续 line 构成新闭合填充；开放路径在结束时隐式闭合。
    @Test func closeAndImplicitClosurePreservePathSequence() throws {
        let outline = GlyphOutline(elements: [.move(.zero), .line(ScenePoint(x: 10, y: 0)),
                                              .line(ScenePoint(x: 0, y: 10)), .close,
                                              .line(ScenePoint(x: -10, y: 0)), .line(ScenePoint(x: 0, y: -10))])
        var budget = try GeometryBudget()
        let contours = try PathFlattening.glyph(outline, tolerance: 0.125, budget: &budget)
        #expect(contours.count == 2 && contours.allSatisfy { $0.first == .zero })
        #expect(try GeometryTestSupport.area(GeometryTestSupport.mesh(contours)) == 100)
        var invalidBudget = try GeometryBudget()
        #expect(throws: PAGError.renderingFailure("geometryPathSequence")) {
            try PathFlattening.glyph(GlyphOutline(elements: [.line(.zero)]), tolerance: 0.125, budget: &invalidBudget)
        }
    }

    /// 解析圆形圆角的面积趋近 πr²，组内放大收紧源容差，反向轮廓保持相同范围。
    @Test func roundedRectanglesUseAnalyticArcsAndNestedScale() throws {
        let ordinary = try RoundedRectangleContour.make(size: ScenePoint(x: 20, y: 20), position: .zero,
                                                                 roundness: 10, reversed: false, matrix: .identity)
        let scaled = try RoundedRectangleContour.make(size: ScenePoint(x: 20, y: 20), position: .zero,
                                                              roundness: 10, reversed: true, matrix: .scale(x: 8, y: 8))
        var firstBudget = try GeometryBudget(), secondBudget = try GeometryBudget()
        let first = try PathFlattening.shape(ShapeGeometry(contours: [.rectangle(ordinary)]), tolerance: 0.125, budget: &firstBudget)
        let second = try PathFlattening.shape(ShapeGeometry(contours: [.rectangle(scaled)]), tolerance: 0.125, budget: &secondBudget)
        #expect(second[0].count > first[0].count)
        let area = try GeometryTestSupport.area(GeometryTestSupport.mesh(first))
        let largeArea = try GeometryTestSupport.area(GeometryTestSupport.mesh(second))
        #expect(area < .pi * 100 && area > .pi * 100 - 8)
        #expect(largeArea < .pi * 6400 && largeArea > .pi * 6400 - 64)
        #expect(second[0].allSatisfy { abs($0.x) <= 80 && abs($0.y) <= 80 })
    }

    /// 不同圆角和旋转/斜切组合都能细分；面积只随矩阵行列式改变，不因方向改变而消失。
    @Test(arguments: [0.0, 1, 5, 10], [0.0, 17, 45, 90, 137])
    func rotatedRoundedRectanglesPreserveArea(radius: Double, angle: Double) throws {
        let rotation = try SceneAffine.rotation(degrees: angle)
        let shear = try SceneAffine(a: 1, b: 0, c: 0.3, d: 1, tx: 12, ty: -9)
        let matrix = try rotation.following(shear)
        let contour = try RoundedRectangleContour.make(size: ScenePoint(x: 40, y: 20),
                                                                    position: .zero, roundness: radius,
                                                                    reversed: false, matrix: matrix)
        var budget = try GeometryBudget()
        let contours = try PathFlattening.shape(ShapeGeometry(contours: [.rectangle(contour)]), tolerance: 0.03125, budget: &budget)
        let mesh = try GeometryTestSupport.mesh(contours)
        let idealArea = 800 - (4 - .pi) * radius * radius
        #expect(abs(GeometryTestSupport.area(mesh) - idealArea) < 3)
    }

    /// 深度和工作量不足时必须失败；取消在首次工作前传播，非有限控制点不能进入网格。
    @Test func depthWorkCancellationAndNonFiniteControlsFail() async throws {
        let outline = GlyphOutline(elements: [.move(.zero), .quadratic(control: ScenePoint(x: 0, y: 100),
                                                                      end: ScenePoint(x: 100, y: 0)), .close])
        var depth = try GeometryBudget(maximumDepth: 0)
        #expect(throws: PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")) {
            try PathFlattening.glyph(outline, tolerance: 0.125, budget: &depth)
        }
        var work = try GeometryBudget(maximumWork: 2)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try PathFlattening.glyph(outline, tolerance: 0.125, budget: &work)
        }
        var finite = try GeometryBudget()
        #expect(throws: PAGError.renderingFailure("geometryNonFinite")) {
            try PathFlattening.glyph(GlyphOutline(elements: [.move(.zero), .quadratic(control: ScenePoint(x: .nan, y: 0),
                                                                                    end: .one)]),
                                     tolerance: 0.125, budget: &finite)
        }
        let task = Task.detached {
            var budget = try GeometryBudget()
            withUnsafeCurrentTask { $0?.cancel() }
            return try PathFlattening.glyph(outline, tolerance: 0.125, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
