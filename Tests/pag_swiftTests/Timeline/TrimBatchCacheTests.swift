import Testing
@testable import pag_swift

/// Trim批次缓存的身份、测量复用及独立预算；不依赖正式PAG入口或显示设备。
struct TrimBatchCacheTests {
    /// 同输入与逐位选择直接返回旧batch，命中工作只扫描轮廓身份，仍收全额保活成本。
    @Test func identicalSelectionReusesOutputAndChargesRetention() throws {
        let input = try inputs()
        let selection = TrimSelection.ranges(mode: .simultaneously, reversed: false,
                                             first: TrimInterval(start: 0.2, end: 0.6), second: nil)
        var cold = try GeometryBudget()
        let first = try TrimPreparation.prepare(input, selection: selection, reusing: [], budget: &cold)
        var warm = try GeometryBudget(maximumWork: 2)
        let second = try TrimPreparation.prepare(input, selection: selection, reusing: [first], budget: &warm)
        #expect(first === second && cold.work > warm.work && warm.work == 2)
        var limited = try GeometryBudget(maximumBytes: first.estimatedBytes - 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try TrimPreparation.prepare(input, selection: selection, reusing: [first], budget: &limited)
        }
        let value = try #require(first.measurements?.first)
        let measure = try #require(value.measure)
        #expect(first.estimatedBytes >= measure.curves.count * 128 + measure.records.count * 32
                + value.path.points.count * 32 + input[0].referencedBytes)
    }

    /// 区间/模式变化只重切片，已有测量足以在冷测量不够的工作预算内完成；反向必须重新测量。
    @Test func changedRangesReuseMeasurementsButDirectionInvalidates() throws {
        let input = try inputs()
        var budget = try GeometryBudget()
        let original = try TrimPreparation.prepare(input, selection: .ranges(mode: .simultaneously, reversed: false,
            first: TrimInterval(start: 0.2, end: 0.4), second: nil), reusing: [], budget: &budget)
        let changed = TrimSelection.ranges(mode: .individually, reversed: false,
                                          first: TrimInterval(start: 0.21, end: 0.3), second: nil)
        var warm = try GeometryBudget()
        let result = try TrimPreparation.prepare(input, selection: changed, reusing: [original], budget: &warm)
        #expect(result !== original)
        #expect(try TrimBatchFixtures.path(result.outputs[0]) !== TrimBatchFixtures.path(original.outputs[0]))
        var limited = try GeometryBudget(maximumWork: warm.work)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try TrimPreparation.prepare(input, selection: changed, reusing: [], budget: &limited)
        }
        var reversedBudget = try GeometryBudget(maximumWork: warm.work)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try TrimPreparation.prepare(input, selection: .ranges(mode: .individually, reversed: true,
                first: TrimInterval(start: 0.21, end: 0.3), second: nil), reusing: [original], budget: &reversedBudget)
        }
    }

    /// 源对象、组矩阵或前序裁剪身份变化均不能复用，数值相同的新源路径也不深比较。
    @Test func sourceAndPriorTrimIdentityInvalidate() throws {
        let path = try TrimBatchFixtures.line(10)
        let input: [ShapeContour] = [.path(path, matrix: .identity)]
        let first = try TrimBatchFixtures.batch(input, TrimBatchFixtures.source(0, 0.5))
        for changed in [[ShapeContour.path(try TrimBatchFixtures.line(10), matrix: .identity)],
                        [.path(path, matrix: try .translation(x: 1, y: 0))], first.outputs] {
            var budget = try GeometryBudget()
            let next = try TrimPreparation.prepare(changed, selection: first.selection, reusing: [first], budget: &budget)
            #expect(next !== first)
        }
        let other = try TrimBatchFixtures.batch(input, TrimBatchFixtures.source(0, 0.5))
        #expect(!first.outputs[0].matches(other.outputs[0]))
        var budget = try GeometryBudget()
        let consecutive = try TrimPreparation.prepare(first.outputs, selection: first.selection, reusing: [], budget: &budget)
        let warm = try TrimPreparation.prepare(first.outputs, selection: first.selection, reusing: [consecutive], budget: &budget)
        #expect(warm === consecutive)
    }

    /// 新增距离溢出、累计溢出、候选上限与取消明确失败，不通过归零或部分输出掩盖问题。
    @Test func precisionLimitsAndCancellationPropagate() async throws {
        let input: [ShapeContour] = [.path(try TrimBatchFixtures.line(10), matrix: .identity)]
        var budget = try GeometryBudget()
        #expect(throws: PAGError.renderingFailure("trimPrecision")) {
            try TrimPreparation.prepare(input, selection: .ranges(mode: .simultaneously, reversed: false,
                first: TrimInterval(start: 0, end: .greatestFiniteMagnitude), second: nil), reusing: [], budget: &budget)
        }
        let huge: [ShapeContour] = [.path(try TrimBatchFixtures.line(2e38), matrix: .identity)]
        #expect(throws: PAGError.renderingFailure("trimPrecision")) {
            try TrimPreparation.prepare(huge + huge, selection: .ranges(mode: .individually, reversed: false,
                first: TrimInterval(start: 0.2, end: 0.4), second: nil), reusing: [], budget: &budget)
        }
        let first = try TrimBatchFixtures.batch(input, TrimBatchFixtures.source(0, 0.5))
        #expect(throws: PAGError.invalidArgument("trimReuseCandidates")) {
            try TrimPreparation.prepare(input, selection: first.selection, reusing: Array(repeating: first, count: 5), budget: &budget)
        }
        let task = Task {
            var budget = try GeometryBudget()
            withUnsafeCurrentTask { $0?.cancel() }
            return try TrimPreparation.prepare(input, selection: first.selection, reusing: [first], budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 一百条非零短线使测量成本显著大于短区间提取，工作门禁能检出隐藏重测。
    private func inputs() throws -> [ShapeContour] {
        let points = (0...100).map { ScenePoint(x: Double($0), y: Double($0 % 2)) }
        let path = try SourcePath(verbs: [.move] + Array(repeating: .line, count: 100), points: points)
        return [.path(path, matrix: .identity)]
    }
}
