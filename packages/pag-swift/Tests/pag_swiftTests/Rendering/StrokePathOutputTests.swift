import Testing
@testable import pag_swift

/// 纯值描边输出保留Double坐标、指令拓扑和失败语义，不需要系统路径桥。
struct StrokePathOutputTests {
    /// 初始化的内存预留失败时，调用方仍看到本次尝试已经消费的工作量。
    @Test func initializationFailureRetainsConsumedWork() throws {
        var budget = try GeometryBudget(maximumBytes: 127)
        try budget.consume(7)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            _ = try StrokePathOutput(budget: &budget, limits: .standard)
        }
        #expect(budget.work == 8)
    }

    /// 有理转换后的三次控制点按原Double保存，输出器不再量化或擅自改变PAG的y方向。
    @Test func cubicCoordinatesRemainDouble() throws {
        let points = [p(1.0 / 3, 2.0 / 7), p(7.0 / 5, 13.0 / 3), p(17.0 / 9, 21.0 / 11), p(4.0 / 7, 9.0 / 13)]
        var outputBudget = try GeometryBudget()
        let output = try StrokePathOutput(budget: &outputBudget, limits: .standard)
        try output.append(.move, points: [points[0]])
        try output.append(.cubic, points: Array(points[1...]))
        let value = try output.finish()
        #expect(value.verbs == [.move, .cubic])
        #expect(value.points == points)
        #expect(value.points[0].x != Double(Float(value.points[0].x)))
    }

    /// 数量、坐标和调用序列在增长前校验，失败不会把非法点写入可完成的局部输出。
    @Test func outputChecksPrecedeStorageGrowth() throws {
        var limitedBudget = try GeometryBudget()
        let limited = try StrokePathOutput(budget: &limitedBudget, limits: StrokeBackendLimits(maximumOutputElements: 1))
        try limited.append(.move, points: [.zero])
        #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeOutputElements")) {
            try limited.append(.line, points: [p(1, 1)])
        }
        var outputBudget = try GeometryBudget()
        let output = try StrokePathOutput(budget: &outputBudget, limits: .standard)
        #expect(throws: PAGError.renderingFailure("strokeNonFinite")) {
            try output.append(.move, points: [p(.infinity, 0)])
        }
        #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeMagnitude")) {
            try output.append(.move, points: [p(16_777_217, 0)])
        }
        #expect(throws: PAGError.renderingFailure("strokePathSequence")) { try output.append(.line, points: [.zero]) }
        #expect(throws: PAGError.invalidArgument("strokeOutputPoints")) { try output.append(.move) }
        try output.append(.move, points: [.zero])
        #expect(try output.finish().points == [.zero])
    }

    /// Close、独立Move和原始三次拓扑保持，完成时统一做一次Double矩阵复原。
    @Test func topologyAndRestorationRemainIndependent() throws {
        var outputBudget = try GeometryBudget()
        let output = try StrokePathOutput(budget: &outputBudget, limits: .standard)
        let source = try SourcePath(verbs: [.move, .line, .close, .move, .cubic], points: [
            .zero, p(2, 3), p(4, 5), p(6, 7), p(8, 9), p(10, 11)])
        var index = 0
        for verb in source.verbs {
            try output.append(verb, points: Array(source.points[index..<(index + verb.pointCount)]))
            index += verb.pointCount
        }
        let matrix = try SceneAffine.translation(x: 1.0 / 3, y: 2.0 / 7)
        let result = try output.finish(restoring: matrix)
        #expect(result.verbs == source.verbs)
        #expect(result.points == source.points.map { p($0.x + 1.0 / 3, $0.y + 2.0 / 7) })
    }

    /// 独立手算点的简写，不执行生产矩阵或几何转换。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }
}
