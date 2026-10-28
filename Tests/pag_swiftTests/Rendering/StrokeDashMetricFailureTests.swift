import Testing
@testable import pag_swift

/// 测量追加的失败原子性与有界策略；已有前缀必须保留，失败工作和字节不能退回。
struct StrokeDashMetricFailureTests {
    /// 第一条新叶已入表后第二条超字节，删除本次后缀；之后重试也不能复用已经消耗的字节。
    @Test func byteFailureRollsBackOnlyNewRecords() throws {
        var budget = try GeometryBudget(maximumBytes: 400)
        var metric = try prefix(budget: &budget)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try metric.append(splitQuad(), curveIndex: 1, budget: &budget)
        }
        expectPrefix(metric)
        #expect(budget.work == 72)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try metric.appendLine(from: .zero, to: SIMD2(1, 0), curveIndex: 1, budget: &budget)
        }
        expectPrefix(metric)
    }

    /// 工作限额恰在左叶成功后耗尽，右节点失败恢复距离和记录；预算不恢复成进入时的值。
    @Test func workFailureRollsBackAcceptedLeftLeaf() throws {
        var budget = try GeometryBudget(maximumWork: 70)
        var metric = try prefix(budget: &budget)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try metric.append(splitQuad(), curveIndex: 1, budget: &budget)
        }
        expectPrefix(metric)
        #expect(budget.work == 70)
    }

    /// 深度只在实际需要继续细分时检查；恰阈值Quad和单位圆允许零深度，放大Conic按需要失败。
    @Test func depthIsCheckedOnlyWhenSubdivisionIsRequired() throws {
        var zero = try GeometryBudget(maximumDepth: 0)
        var metric = StrokeDashMetric()
        try metric.append(StrokeQuadCurve(start: .zero, control: .zero, end: SIMD2(2, 0)), curveIndex: 0, budget: &zero)
        try metric.append(quarter(radius: 1), curveIndex: 1, budget: &zero)
        let previous = metric.distance
        #expect(throws: PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")) {
            try metric.append(StrokeQuadCurve(start: .zero, control: .zero, end: SIMD2(Float(2).nextUp, 0)),
                              curveIndex: 2, budget: &zero)
        }
        #expect(throws: PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")) {
            try metric.append(quarter(radius: 4), curveIndex: 2, budget: &zero)
        }
        #expect(metric.distance == previous && metric.records.count == 2)
        var one = try GeometryBudget(maximumDepth: 1)
        var deeper = StrokeDashMetric()
        try deeper.append(quarter(radius: 4), curveIndex: 0, budget: &one)
        #expect(deeper.records.count == 2)
        #expect(throws: PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")) {
            try deeper.append(quarter(radius: 8), curveIndex: 1, budget: &one)
        }
        #expect(deeper.records.count == 2 && deeper.distance.bitPattern == 0x40C3EF15)
    }

    /// 整数右分支在depth20仍可细分；全局Conic在depth21成功，不能把参数停止条件简化为20层。
    @Test func integerParameterAllowsTwentyFirstLevel() throws {
        let curve = try StrokeConicCurve(start: .zero, control: SIMD2(16, 0), end: .zero, weight: 262_144)
        var shallow = try GeometryBudget(maximumDepth: 20)
        var rejected = StrokeDashMetric()
        #expect(throws: PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")) {
            try rejected.append(curve, curveIndex: 6, budget: &shallow)
        }
        #expect(rejected.distance == 0 && rejected.records.isEmpty)
        #expect(shallow.work > 1_000)
        var deep = try GeometryBudget(maximumDepth: 21)
        var accepted = StrokeDashMetric()
        try accepted.append(curve, curveIndex: 6, budget: &deep)
        // 独立源公式得到81个节点、41个增长叶段；末端细分集中，不需要百万节点压力来测此边界。
        #expect(accepted.records.count == 41)
        #expect(accepted.distance.bitPattern == 0x41FFFFBE)
        #expect(accepted.records.last?.parameter.bitPattern == 0x3F800000)
        #expect(accepted.records.allSatisfy { $0.curve == 6 })
    }

    /// 必需的Conic中点或曲率偏差不可表示时明确失败，不能把上游略过子树解释为成功空结果。
    @Test func nonFiniteConicMidpointAndDeviationFail() throws {
        for curve in [
            try StrokeConicCurve(start: .zero, control: SIMD2(Float.greatestFiniteMagnitude, 0), end: .zero, weight: 2),
            try StrokeConicCurve(start: SIMD2(2e38, 0), control: SIMD2(2e38, 0), end: SIMD2(2e38, 0), weight: 0.5)
        ] {
            var budget = try GeometryBudget()
            var metric = try prefix(budget: &budget)
            #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
                try metric.append(curve, curveIndex: 1, budget: &budget)
            }
            expectPrefix(metric)
        }
    }

    /// Quad偏差和端点差的溢出都明确失败，不能借Double回退补救已经丢失的Float几何。
    @Test func quadArithmeticOverflowFailsCompletely() throws {
        let huge = Float.greatestFiniteMagnitude
        for curve in [
            try StrokeQuadCurve(start: SIMD2(-huge, 0), control: .zero, end: SIMD2(huge, 0)),
            try StrokeQuadCurve(start: SIMD2(2e38, 0), control: SIMD2(2e38, 0), end: SIMD2(2e38, 0))
        ] {
            var budget = try GeometryBudget()
            var metric = try prefix(budget: &budget)
            #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
                try metric.append(curve, curveIndex: 1, budget: &budget)
            }
            expectPrefix(metric)
        }
    }

    /// raw Line/Cubic全部输入点先检查有限性；索引错误独立报告，失败后仍可在同一metric正常追加。
    @Test func invalidRawInputsAndIndexDoNotPoisonMetric() throws {
        var budget = try GeometryBudget()
        var metric = try prefix(budget: &budget)
        #expect(throws: PAGError.invalidArgument("strokeDashCurveIndex")) {
            try metric.appendLine(from: .zero, to: SIMD2(1, 0), curveIndex: -1, budget: &budget)
        }
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try metric.appendLine(from: SIMD2(.infinity, 0), to: .zero, curveIndex: 1, budget: &budget)
        }
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try metric.appendCubic(from: .zero, firstControl: .zero, secondControl: SIMD2(0, .nan),
                                   to: .zero, curveIndex: 1, budget: &budget)
        }
        expectPrefix(metric)
        try metric.appendLine(from: .zero, to: SIMD2(2, 0), curveIndex: 1, budget: &budget)
        #expect(metric.distance == 3 && metric.records.map(\.curve) == [0, 1])
    }

    /// 已有前缀后确定性取消，入口抛CancellationError且恢复仍然执行；不发布取消后的曲线。
    @Test func cancellationPreservesExistingPrefix() async throws {
        let task = Task {
            var budget = try GeometryBudget()
            var metric = try prefix(budget: &budget)
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try metric.append(splitQuad(), curveIndex: 1, budget: &budget) }
            expectPrefix(metric)
            #expect(budget.work == 2)
        }
        try await task.value
    }

    /// 实际临时路径入口在首Line成功后遇到Cubic超深度，必须抛错，不能返回前缀测量表。
    @Test func sourceMeasureNeverPublishesSuccessfulPrefixOnLaterFailure() throws {
        var setup = try GeometryBudget()
        let source = try StrokePath(verbs: [.move, .line, .cubic],
                                    points: [.zero, ScenePoint(x: 1, y: 0), ScenePoint(x: 1, y: 12),
                                             ScenePoint(x: 12, y: 12), ScenePoint(x: 12, y: 0)], budget: &setup)
        let contour = StrokeSubpath(verbs: 0..<3, points: 0..<5, lengthUpperBound: 36, hasSegments: true, isClosed: false)
        var budget = try GeometryBudget(maximumDepth: 0)
        #expect(throws: PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")) {
            try StrokeDashMeasure.make(source, contour: contour, budget: &budget)
        }
        #expect(budget.work > 4)
    }

    /// 先成功提交距离1的直线，便于区分追加回滚与错误清空整表。
    private func prefix(budget: inout GeometryBudget) throws -> StrokeDashMetric {
        var metric = StrokeDashMetric()
        try metric.appendLine(from: .zero, to: SIMD2(1, 0), curveIndex: 0, budget: &budget)
        return metric
    }

    /// 验证已有前缀的所有可观察字段，没有为比较而保存metric数组快照。
    private func expectPrefix(_ metric: StrokeDashMetric) {
        #expect(metric.distance == 1 && metric.records.count == 1)
        #expect(metric.records.first?.curve == 0 && metric.records.first?.parameter == 1)
        #expect(metric.records.first?.distance == 1)
    }

    /// 根需半切一次，两个叶长分别为1和3；可精确注入第一叶成功后的预算错误。
    private func splitQuad() throws -> StrokeQuadCurve {
        try StrokeQuadCurve(start: .zero, control: .zero, end: SIMD2(4, 0))
    }

    /// 单位权重以外的标准四分圆，深度由半径控制。
    private func quarter(radius: Float) throws -> StrokeConicCurve {
        try StrokeConicCurve(start: SIMD2(radius, 0), control: SIMD2(radius, radius),
                             end: SIMD2(0, radius), weight: Float(bitPattern: 0x3F3504F3))
    }
}
