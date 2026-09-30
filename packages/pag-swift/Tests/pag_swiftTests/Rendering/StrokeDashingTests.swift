import Testing
@testable import pag_swift

/// 按固定SkDashPath状态机的手算拓扑核验零间隔、闭合缝、相位、退化及实际资源限制。
struct StrokeDashingTests {
    /// 开放零on保留精确点，零off仍分隔两个on；不能变成1/65536长的CG短线。
    @Test func openZeroIntervalsPreserveExactTopology() throws {
        let source = try path([[p(0, 0), p(30, 0)]])
        let points = try dash(source, intervals: [0, 10])
        // 1/3不是精确Float，Double输出保留该参数误差；零Line两端相等则必须逐位成立。
        try expect(points, equals: [[p(0, 0), p(0, 0)], [p(10, 0), p(10, 0)], [p(20, 0), p(20, 0)]], accuracy: 1e-6)
        for index in stride(from: 0, to: points.points.count, by: 2) { #expect(points.points[index] == points.points[index + 1]) }
        try expect(dash(source, intervals: [10, 0]), equals: [[p(0, 0), p(10, 0)], [p(10, 0), p(20, 0)], [p(20, 0), p(30, 0)]], accuracy: 1e-6)
    }

    /// 闭合方形的首on延后输出，是否续接由最后一轮（包括零off）决定，所有结果没有Close。
    @Test func closedSeamsFollowInitialAndFinalIntervals() throws {
        let a = p(0, 0), b = p(10, 0), c = p(10, 10), d = p(0, 10)
        let source = try path(verbs: [.move, .line, .line, .line, .close], points: [a, b, c, d])
        let cases: [(intervals: [Double], phase: Double, contours: [[ScenePoint]])] = [
            ([0, 10], 0, [[b, b], [c, c], [d, d], [a, a]]),
            ([10, 0], 0, [[b, b, c], [c, c, d], [d, d, a, b]]),
            ([0, 0, 0, 10], 0, [[a, a], [b, b], [b, b], [c, c], [c, c], [d, d], [d, d], [a, a]]),
            ([10, 10], 0, [[c, c, d], [a, b]]),
            ([10, 10], 10, [[b, b, c], [d, d, a]]),
            ([10, 20], 0, [[d, d, a, b]]),
            ([40, 10], 0, [[a, b, c, d, a]]),
            ([10, 0, 10, 10], 10, [[a, b], [c, c, d], [d, d, a]])
        ]
        for item in cases {
            try expect(dash(source, intervals: item.intervals, phase: item.phase), equals: item.contours)
        }
        try expect(dash(source, intervals: [0, 10], phase: 5), equals: [[p(5, 0), p(5, 0)], [p(10, 5), p(10, 5)],
                                                                     [p(5, 10), p(5, 10)], [p(0, 5), p(0, 5)]])
    }

    /// 负phase规范化后每个子路径从同一间隔开始，正周期整倍数等于零相位。
    @Test func phaseRestartsForEachContour() throws {
        let source = try path([[.zero, p(25, 0)], [p(100, 0), p(125, 0)]])
        try expect(dash(source, intervals: [10, 10], phase: -5), equals: [[p(5, 0), p(15, 0)], [p(105, 0), p(115, 0)]], accuracy: 1e-6)
        let zero = try dash(source, intervals: [0, 10])
        let cycle = try dash(source, intervals: [0, 10], phase: 10)
        #expect(zero.verbs == cycle.verbs && zero.points == cycle.points)
    }

    /// 有效dash会去掉无测量退化轮廓；无效effect仍原样保留，唯一零Line先经中心线特判可留下零on。
    @Test func degenerateContoursRespectDashBeforeCaps() throws {
        let source = try path(verbs: [.move, .close, .move, .cubic, .close], points: Array(repeating: .zero, count: 5))
        #expect(try dash(source, intervals: [0, 10]).verbs.isEmpty)
        let unchanged = try dash(source, intervals: [0, 0])
        #expect(unchanged.verbs == source.verbs && unchanged.points == source.points)
        let line = try SourcePath(verbs: [.move, .line], points: [.zero, .zero])
        let style = try style([0, 10], phase: 0)
        let geometry = try ShapeGeometry(contours: [.path(line, matrix: .identity)], stroke: ShapeStroke(style: style, matrix: .identity))
        var budget = try GeometryBudget()
        let centerline = try StrokeCenterline.make(geometry, budget: &budget)
        let result = try StrokeDashing.make(centerline, style: style, budget: &budget)
        try expect(result, equals: [[.zero, .zero]])
    }

    /// dash后的真实输入限制独立于较大的输出限额；Float影子放大测量长度时实际on次数仍有硬上限。
    @Test func actualOutputAndInputAreBothBounded() throws {
        let source = try path([[.zero, p(30, 0)]])
        for (limits, name) in [(try StrokeBackendLimits(maximumInputVerbs: 2), "maximumStrokeInputVerbs"),
                              (try StrokeBackendLimits(maximumInputPoints: 2), "maximumStrokeInputPoints"),
                              (try StrokeBackendLimits(maximumSubpaths: 2), "maximumStrokeSubpaths")] {
            var budget = try GeometryBudget()
            #expect(throws: PAGError.resourceLimitExceeded(name)) {
                try StrokeDashing.make(source, style: style([0, 10], phase: 0), limits: limits, budget: &budget)
            }
        }
        let zigzag = try path([(0...100).map { p(1_000_000 + ($0.isMultiple(of: 2) ? -0.032 : 0.032), 0) }])
        let limits = try StrokeBackendLimits(maximumDashPieces: 6)
        let style = try style([1, 1], phase: 0)
        var budget = try GeometryBudget()
        #expect(try StrokeAdmission.inspect(zigzag, style: style, limits: limits, budget: &budget).dashPieceUpperBound == 6)
        #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeDashPieces")) {
            try StrokeDashing.make(zigzag, style: style, limits: limits, budget: &budget)
        }
    }

    /// 低字节、低工作及预取消都终止虚线准备，不发布半段结果或退回实线。
    @Test func budgetsAndCancellationDoNotReturnPartialPaths() async throws {
        let source = try path([[.zero, p(30, 0)]])
        let style = try style([0, 10], phase: 0)
        for (budget, name) in [(try GeometryBudget(maximumBytes: 1), "maximumRenderGeometryBytes"),
                              (try GeometryBudget(maximumWork: 1), "maximumRenderGeometryWork")] {
            var budget = budget
            #expect(throws: PAGError.resourceLimitExceeded(name)) { try StrokeDashing.make(source, style: style, budget: &budget) }
        }
        let task = Task {
            var budget = try GeometryBudget()
            withUnsafeCurrentTask { $0?.cancel() }
            return try StrokeDashing.make(source, style: style, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 从源规范化逻辑创建样式，nil表示上游允许的无效effect回落。
    private func style(_ intervals: [Double], phase: Double) throws -> StrokeStyle {
        try StrokeStyle(width: 4, cap: .round, join: .round, miterLimit: 4, dashes: StrokeDashPattern.make(intervals: intervals, phase: phase))
    }

    /// 用独立预算调用实际虚线适配入口。
    private func dash(_ path: StrokePath, intervals: [Double], phase: Double = 0) throws -> StrokePath {
        var budget = try GeometryBudget()
        return try StrokeDashing.make(path, style: style(intervals, phase: phase), budget: &budget)
    }

    /// 手写轮廓序列为独立期望；默认点逐位相等，非二进制Float参数场景显式给位置误差。
    private func expect(_ actual: StrokePath, equals contours: [[ScenePoint]], accuracy: Double = 0) throws {
        let expected = try path(contours)
        #expect(actual.verbs == expected.verbs)
        try #require(actual.points.count == expected.points.count)
        for (actual, expected) in zip(actual.points, expected.points) {
            #expect(abs(actual.x - expected.x) <= accuracy && abs(actual.y - expected.y) <= accuracy)
        }
    }

    /// 把多个开放折线组合为语义路径，既不焊接也不补Close。
    private func path(_ contours: [[ScenePoint]]) throws -> StrokePath {
        try path(verbs: contours.flatMap { [.move] + Array(repeating: .line, count: $0.count - 1) }, points: contours.flatMap { $0 })
    }

    /// 在独立准备预算中发布临时测试路径；测试执行预算不包含夹具构造成本。
    private func path(verbs: [StrokePathVerb], points: [ScenePoint]) throws -> StrokePath {
        var setup = try GeometryBudget()
        return try StrokePath(verbs: verbs, points: points, budget: &setup)
    }

    /// 简写独立期望中的Double坐标。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }
}
