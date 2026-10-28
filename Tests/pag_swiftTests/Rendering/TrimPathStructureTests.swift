import Testing
@testable import pag_swift

/// Trim共用曲线结构、反转和独立于描边接纳的轮廓索引。
struct TrimPathStructureTests {
    /// 多轮廓整体反向保留尾Move、Close和零段，并颠倒轮廓顺序。
    @Test func reversalPreservesStoredTopology() throws {
        var budget = try GeometryBudget()
        let path = try StrokePath(verbs: [.move, .line, .move, .line, .close, .move],
            points: [point(0), point(10), point(20), point(30), point(99)], budget: &budget)
        let result = try TrimPathReversal.reversed(path, budget: &budget)
        #expect(result.verbs == [.move, .move, .line, .close, .move, .line])
        #expect(result.points == [point(99), point(30), point(20), point(10), point(0)])
        let twice = try TrimPathReversal.reversed(result, budget: &budget)
        #expect(twice.verbs == path.verbs && twice.points == path.points)
        let zero = try StrokePath(verbs: [.move, .line, .move, .close],
            points: [point(0), point(0), point(1)], budget: &budget)
        let reversed = try TrimPathReversal.reversed(zero, budget: &budget)
        #expect(reversed.verbs == [.move, .close, .move, .line])
        #expect(reversed.points == [point(1), point(0), point(0)])
    }

    /// Quad保持唯一控制点、Conic保持权重、Cubic交换控制点，最终从原末点走回原起点。
    @Test func reversedCurvesKeepTheirTypesAndControls() throws {
        var budget = try GeometryBudget()
        let path = try StrokePath(verbs: [.move, .quad, .conic(weight: 0.5), .cubic],
            points: (0...7).map { point(Double($0)) }, budget: &budget)
        let result = try TrimPathReversal.reversed(path, budget: &budget)
        #expect(result.verbs == [.move, .cubic, .conic(weight: 0.5), .quad])
        #expect(result.points == (0...7).reversed().map { point(Double($0)) })
    }

    /// 初始Line和Close后Line按源SkPath补Move；通用索引保留所有独立Move及空轮廓。
    @Test func normalizationAndIndexingKeepEmptyContours() throws {
        var budget = try GeometryBudget()
        let source = try SourcePath(verbs: [.line, .close, .line, .move, .move],
            points: [point(10), point(20), point(30), point(40)])
        var writer = TrimPathWriter(budget: budget)
        try writer.append(source, matrix: StrokeFloatTransform(.identity), inverse: nil)
        let path = try writer.finish()
        budget = writer.budget
        #expect(path.verbs == [.move, .line, .close, .move, .line, .move, .move])
        #expect(path.points == [point(0), point(10), point(0), point(20), point(30), point(40)])
        let ranges = try CurveContourIndex.ranges(in: path, budget: &budget)
        #expect(ranges.map(\.verbs) == [0..<3, 3..<5, 5..<6, 6..<7])
        #expect(ranges.map(\.points) == [0..<2, 2..<4, 4..<5, 5..<6])
        #expect(ranges.map(\.isClosed) == [true, false, false, false])
    }

    /// Trim写入/索引不借用Stroke的16k指令或幅度上限，实际工作与内存仍有预算。
    @Test func generalCurvePolicyDoesNotInheritStrokeLimits() throws {
        var writer = TrimPathWriter(budget: try GeometryBudget())
        try writer.append(.move, points: [point(33_554_432)])
        for _ in 0..<16_385 { try writer.append(.line, points: [point(33_554_432)]) }
        let path = try writer.finish()
        let ranges = try CurveContourIndex.ranges(in: path, budget: &writer.budget)
        #expect(path.verbs.count == 16_386 && ranges.count == 1)
        #expect(try StrokeDashMeasure.make(path, contour: ranges[0], budget: &writer.budget) == nil)
        var limited = try GeometryBudget(maximumBytes: 127)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try CurveContourIndex.ranges(in: path, budget: &limited)
        }
    }

    /// 反转和索引使用调用者同一份工作预算；预取消在任何曲线输出之前失败。
    @Test func budgetsAndCancellationCoverStructureWork() async throws {
        var budget = try GeometryBudget()
        let path = try StrokePath(verbs: [.move, .line], points: [point(0), point(1)], budget: &budget)
        var limited = try GeometryBudget(maximumWork: 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try TrimPathReversal.reversed(path, budget: &limited)
        }
        await #expect(throws: CancellationError.self) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                let preparedBudget = try GeometryBudget()
                group.cancelAll()
                group.addTask {
                    var budget = preparedBudget
                    _ = try CurveContourIndex.ranges(in: path, budget: &budget)
                }
                for try await _ in group {}
            }
        }
    }

    /// 在水平轴上布置可手算的点，避免几何夹具依赖生产路径生成器。
    private func point(_ x: Double) -> ScenePoint { ScenePoint(x: x, y: 0) }
}
