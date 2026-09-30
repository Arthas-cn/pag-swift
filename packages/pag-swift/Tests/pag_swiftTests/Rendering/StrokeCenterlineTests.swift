import Testing
@testable import pag_swift

/// 描边中心线的源码拓扑、矩形起点、Float坐标边界和预算；不借用CG描边结果当期望值。
struct StrokeCenterlineTests {
    /// 初始Line补原点，Close后Line回到最近Move；重复Close不新增轮廓，重复点与零Cubic必须保留。
    @Test func preservesSourceTopologyAndImplicitMoves() throws {
        let source = try SourcePath(verbs: [.close, .line, .close, .close, .line, .move, .line, .cubic, .close],
            points: [p(10, 0), p(20, 0), p(5, 7), p(5, 7), p(5, 7), p(5, 7), p(5, 7)])
        let result = try centerline([.path(source, matrix: .identity)])
        #expect(result.verbs == [.move, .line, .close, .move, .line, .move, .line, .cubic, .close])
        #expect(result.points == [p(0, 0), p(10, 0), p(0, 0), p(20, 0), p(5, 7), p(5, 7), p(5, 7), p(5, 7), p(5, 7)])
    }

    /// 独立源路径不相连，纯Move和Move+Close保留到描边消费者决定是否产生端帽。
    @Test func separatePathsDoNotWeldAndEmptyContoursRemain() throws {
        let first = try SourcePath(verbs: [.move, .line], points: [p(1, 0), p(2, 0)])
        let second = try SourcePath(verbs: [.line, .move, .close, .move], points: [p(3, 0), p(4, 0), p(5, 0)])
        let result = try centerline([.path(first, matrix: .identity), .path(second, matrix: .identity)])
        #expect(result.verbs == [.move, .line, .move, .line, .move, .close, .move])
        #expect(result.points == [p(1, 0), p(2, 0), p(0, 0), p(3, 0), p(4, 0), p(5, 0)])
    }

    /// 只有整个累计路径恰为零Line且dash有效时扰动终点；额外Close、多轮廓和全零Cubic都不扰动。
    @Test func dashPerturbationAppliesOnlyToWholeZeroLine() throws {
        let dash = try #require(try StrokeDashPattern.make(intervals: [0, 10], phase: 0))
        let line = try SourcePath(verbs: [.move, .line], points: [.zero, .zero])
        let contour = ShapeContour.path(line, matrix: .identity)
        #expect(try centerline([contour]).points == [.zero, .zero])
        let perturbed = try centerline([contour], dashes: dash)
        #expect(perturbed.points == [.zero, p(Double(Float(1.001) / 4096), 0)])
        #expect(try centerline([contour, contour], dashes: dash).points == Array(repeating: .zero, count: 4))
        for verbs: [SourcePathVerb] in [[.move, .line, .close], [.move, .close], [.move, .cubic]] {
            let points = Array(repeating: ScenePoint.zero, count: verbs.reduce(0) { $0 + $1.pointCount })
            let path = try SourcePath(verbs: verbs, points: points)
            #expect(try centerline([.path(path, matrix: .identity)], dashes: dash).points == points)
        }
        // 负大坐标处源码Float加法可能不推进；不能为了制造非零长度改成Double扰动。
        let large = try SourcePath(verbs: [.move, .line], points: [p(-1_000_000, 0), p(-1_000_000, 0)])
        #expect(try centerline([.path(large, matrix: .identity)], dashes: dash).points == large.points)
    }

    /// 普通矩形从右上起步，反向不受负尺寸再次翻转；零尺寸仍留下闭合中心线。
    @Test func rectanglesKeepStartDirectionAndDegeneracy() throws {
        for reversed in [false, true] {
            let rectangle = try RoundedRectangleContour.make(size: p(-20, 10), position: .zero,
                roundness: 5, reversed: reversed, matrix: .identity)
            let result = try centerline([.rectangle(rectangle)])
            #expect(rectangle.radius == 0)
            #expect(result.verbs == [.move, .line, .line, .line, .close])
            #expect(result.points == (reversed ? [p(10, -5), p(-10, -5), p(-10, 5), p(10, 5)]
                                               : [p(10, -5), p(10, 5), p(-10, 5), p(-10, -5)]))
        }
        let zero = try RoundedRectangleContour.make(size: p(0, 10), position: .zero,
            roundness: 5, reversed: false, matrix: .identity)
        #expect(!zero.hasArea)
        #expect(try centerline([.rectangle(zero)]).points == [p(0, -5), p(0, 5), p(0, 5), p(0, -5)])
    }

    /// 圆角矩形固定从右上圆角下端开始，保留四Conic；反向最后的直边由Close补齐。
    @Test func roundedRectanglesPreserveAsymmetricVerbOrder() throws {
        for reversed in [false, true] {
            let rectangle = try RoundedRectangleContour.make(size: p(40, 20), position: .zero,
                roundness: 4, reversed: reversed, matrix: .identity)
            let result = try centerline([.rectangle(rectangle)])
            #expect(result.points.first == p(20, -6) && result.verbs.last == .close)
            #expect(ends(of: .line, in: result) == (reversed ? [p(-16, -10), p(-20, 6), p(16, 10)]
                : [p(20, 6), p(-16, 10), p(-20, -6), p(16, -10)]))
            let corners = reversed ? [p(16, -10), p(-20, -6), p(-16, 10), p(20, 6)]
                                   : [p(16, 10), p(-20, 6), p(-16, -10), p(20, -6)]
            let endpoints = ends(of: .conic(weight: Float(0.707106781)), in: result)
            #expect(endpoints == corners)
            #expect(result.verbs.filter { $0 == .conic(weight: Float(0.707106781)) }.count == 4)
        }
    }

    /// 正方形最大圆角进入oval，从右侧中点起步；顺逆两向保留四个轴端点并且不插直线。
    @Test func ovalUsesRightMiddleAndFourConics() throws {
        for reversed in [false, true] {
            let circle = try RoundedRectangleContour.make(size: p(20, 20), position: .zero,
                roundness: 10, reversed: reversed, matrix: .identity)
            let result = try centerline([.rectangle(circle)])
            let cardinal = reversed ? [p(0, -10), p(-10, 0), p(0, 10), p(10, 0)]
                                    : [p(0, 10), p(-10, 0), p(0, -10), p(10, 0)]
            #expect(result.points.first == p(10, 0) && !result.verbs.contains(.line))
            #expect(ends(of: .conic(weight: Float(0.707106781)), in: result) == cardinal)
            #expect(result.verbs.count == 6 && result.points.count == 9)
        }
    }

    /// 只有一边达到圆角直径仍是普通rrect，左右零边不能被oval优化删除。
    @Test func capsuleKeepsZeroLinesBeforeDashing() throws {
        let rectangle = try RoundedRectangleContour.make(size: p(40, 20), position: .zero,
            roundness: 10, reversed: false, matrix: .identity)
        let result = try centerline([.rectangle(rectangle)])
        let conic = StrokePathVerb.conic(weight: Float(0.707106781))
        #expect(result.verbs == [.move, .line, conic, .line, conic, .line, conic, .line, conic, .close])
        #expect(result.points == [p(20, 0), p(20, 0), p(20, 10), p(10, 10), p(-10, 10),
            p(-20, 10), p(-20, 0), p(-20, 0), p(-20, -10), p(-10, -10), p(10, -10), p(20, -10), p(20, 0)])
    }

    /// builder与发布模型分别计费；发布点数组预算不足时不返回已经完整构造的前缀。
    @Test func publishingChargesBothTemporaryAndRetainedStorage() throws {
        var builder = StrokePathBuilder(budget: try GeometryBudget(maximumBytes: 319), limits: .standard)
        try builder.append(.move, points: [.zero])
        try builder.append(.line, points: [p(1, 0)])
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) { try builder.finish() }
        var exact = StrokePathBuilder(budget: try GeometryBudget(maximumBytes: 320), limits: .standard)
        try exact.append(.move, points: [.zero])
        try exact.append(.line, points: [p(1, 0)])
        #expect(try exact.finish().verbs == [.move, .line])
    }

    /// Float MakeXYWH保存真实边界；大原点导致边长缩小时，圆角要按新边界再次收紧。
    @Test func roundedBoundsUseActualFloatSpan() throws {
        let rectangle = try RoundedRectangleContour.make(size: p(3, 10), position: p(16_777_216, 0),
            roundness: 1.5, reversed: false, matrix: .identity)
        #expect(rectangle.left == 16_777_214 && rectangle.right == 16_777_216)
        #expect(rectangle.size == p(2, 10) && rectangle.radius == 1)
    }

    /// 轮廓组矩阵和paint逆矩阵分两次Float计算；奇异paint不再还原矩阵，也不丢掉退化中心线。
    @Test func floatStagesAndSingularPaintRemainDistinct() throws {
        let path = try SourcePath(verbs: [.move, .line], points: [p(1, 2), p(3, 4)])
        let translation = try SceneAffine.translation(x: 16_777_216, y: 0)
        let result = try centerline([.path(path, matrix: translation)], paint: translation)
        #expect(result.points == [p(0, 2), p(4, 4)])
        let singular = try SceneAffine.scale(x: 0, y: 2)
        let stroke = try ShapeStroke(style: style(), matrix: singular)
        #expect(stroke.inverse == nil && stroke.restoration == .identity)
        #expect(try centerline([.path(path, matrix: singular)], paint: singular).points == [p(0, 4), p(0, 8)])
    }

    /// 新增Move也计入输入限制，字节/工作/坐标超限明确失败；不发布截断路径。
    @Test func inputAndGeometryBudgetsFailBeforeGrowth() throws {
        let path = try SourcePath(verbs: [.line, .move, .line], points: [p(1, 0), p(2, 0), p(3, 0)])
        let geometry = try ShapeGeometry(contours: [.path(path, matrix: .identity)], stroke: ShapeStroke(style: style(), matrix: .identity))
        for (limits, name) in [(try StrokeBackendLimits(maximumInputVerbs: 3), "maximumStrokeInputVerbs"),
                               (try StrokeBackendLimits(maximumInputPoints: 3), "maximumStrokeInputPoints"),
                               (try StrokeBackendLimits(maximumSubpaths: 1), "maximumStrokeSubpaths"),
                               (try StrokeBackendLimits(maximumMagnitude: 2), "maximumStrokeMagnitude")] {
            var budget = try GeometryBudget()
            #expect(throws: PAGError.resourceLimitExceeded(name)) {
                try StrokeCenterline.make(geometry, limits: limits, budget: &budget)
            }
        }
        for (budget, name) in [(try GeometryBudget(maximumBytes: 1), "maximumRenderGeometryBytes"),
                               (try GeometryBudget(maximumWork: 1), "maximumRenderGeometryWork")] {
            var budget = budget
            #expect(throws: PAGError.resourceLimitExceeded(name)) {
                try StrokeCenterline.make(geometry, budget: &budget)
            }
        }
    }

    /// 预取消即使输入为空也传播；缺少描边信息不能默默当成填充中心线。
    @Test func cancellationAndMissingStrokeFail() async throws {
        let plain = try ShapeGeometry(contours: [])
        var budget = try GeometryBudget()
        #expect(throws: PAGError.invalidArgument("missingShapeStroke")) {
            try StrokeCenterline.make(plain, budget: &budget)
        }
        let geometry = try ShapeGeometry(contours: [], stroke: ShapeStroke(style: style(), matrix: .identity))
        let task = Task {
            var budget = try GeometryBudget()
            withUnsafeCurrentTask { $0?.cancel() }
            return try StrokeCenterline.make(geometry, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 构造简单点值，使测试里的几何期望直接可读。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }

    /// 本组只验证中心线，使用固定正宽和端帽，dash按测试显式提供。
    private func style(dashes: StrokeDashPattern? = nil) -> StrokeStyle {
        StrokeStyle(width: 4, cap: .round, join: .round, miterLimit: 4, dashes: dashes)
    }

    /// 通过实际中心线入口执行独立轮廓和paint变换，保留原Conic而不指定近似容差。
    private func centerline(_ contours: [ShapeContour], paint: SceneAffine = .identity,
                            dashes: StrokeDashPattern? = nil) throws -> StrokePath {
        let geometry = try ShapeGeometry(contours: contours, stroke: ShapeStroke(style: style(dashes: dashes), matrix: paint))
        var budget = try GeometryBudget()
        return try StrokeCenterline.make(geometry, budget: &budget)
    }

    /// 从实际规范化输出提取指定指令的终点；不重做矩形或Conic构造算法。
    private func ends(of target: StrokePathVerb, in path: StrokePath) -> [ScenePoint] {
        var points: [ScenePoint] = []
        var index = 0
        for verb in path.verbs {
            index += verb.pointCount
            if verb == target, verb.pointCount > 0 { points.append(path.points[index - 1]) }
        }
        return points
    }
}
