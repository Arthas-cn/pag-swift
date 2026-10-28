import Testing
@testable import pag_swift

/// 临时dash输出器的拓扑、权重规范化和成本政策；不经过最终SourcePath出口。
struct StrokeDashOutputTests {
    /// Quad和非单位Conic保留，单位Conic转Quad；零Line必须逐位复制实际Double末点。
    @Test func retainsCurvesAndNormalizesOnlyUnitWeight() throws {
        var budget = try GeometryBudget()
        let output = try StrokeDashOutput(budget: &budget, limits: .standard)
        let end = ScenePoint(x: Double(3).nextUp, y: Double(4).nextDown)
        try output.append(.move, points: [.zero])
        try output.append(.quad, points: [p(1, 2), p(2, 0)])
        try output.append(.conic(weight: 0.5), points: [p(2, 2), p(3, 0)])
        try output.append(.conic(weight: 1), points: [p(3, 2), end])
        try output.appendZeroLengthLine()
        let path = try output.finish()
        #expect(path.verbs == [.move, .quad, .conic(weight: 0.5), .quad, .line])
        #expect(Array(path.points.suffix(2)) == [end, end])
    }

    /// 中间输出使用elements限额；中心线输入配额不能提前限制dash数组。
    @Test func outputDoesNotApplyInputQuotas() throws {
        var budget = try GeometryBudget()
        let limits = try StrokeBackendLimits(maximumInputVerbs: 1, maximumInputPoints: 1, maximumSubpaths: 1)
        let output = try StrokeDashOutput(budget: &budget, limits: limits)
        try output.append(.move, points: [.zero])
        try output.append(.quad, points: [p(1, 1), p(2, 0)])
        try output.append(.close)
        try output.append(.move, points: [p(4, 0)])
        try output.appendZeroLengthLine()
        let path = try output.finish()
        #expect(path.verbs == [.move, .quad, .close, .move, .line])
        #expect(path.points.count == 5)
    }

    /// 初始绘制和Close之后缺Move都失败，重复Close及无当前点的零Line同样拒绝。
    @Test func rejectsMissingOrClosedMove() throws {
        for closesFirst in [false, true] {
            for verb: StrokePathVerb in [.line, .quad, .conic(weight: 0.5), .cubic, .close] {
                var budget = try GeometryBudget()
                let output = try StrokeDashOutput(budget: &budget, limits: .standard)
                if closesFirst {
                    try output.append(.move, points: [.zero])
                    try output.append(.close)
                }
                #expect(throws: PAGError.renderingFailure("strokePathSequence")) {
                    try output.append(verb, points: Array(repeating: .zero, count: verb.pointCount))
                }
            }
            var budget = try GeometryBudget()
            let output = try StrokeDashOutput(budget: &budget, limits: .standard)
            if closesFirst {
                try output.append(.move, points: [.zero])
                try output.append(.close)
            }
            #expect(throws: PAGError.renderingFailure("strokePathSequence")) { try output.appendZeroLengthLine() }
        }
    }

    /// 非法点数、坐标、权重及幅度各走明确错误，不靠模型发布时才发现。
    @Test func validatesEachAppendBeforeStorage() throws {
        var setup = try GeometryBudget()
        let count = try StrokeDashOutput(budget: &setup, limits: .standard)
        #expect(throws: PAGError.invalidArgument("strokeOutputPoints")) { try count.append(.move) }
        for coordinate in [Double.nan, .infinity] {
            let output = try StrokeDashOutput(budget: &setup, limits: .standard)
            #expect(throws: PAGError.renderingFailure("strokeNonFinite")) {
                try output.append(.move, points: [p(coordinate, 0)])
            }
        }
        for weight: Float in [0, -1, .nan, .infinity] {
            let output = try StrokeDashOutput(budget: &setup, limits: .standard)
            try output.append(.move, points: [.zero])
            #expect(throws: PAGError.invalidArgument("strokeConicWeight")) {
                try output.append(.conic(weight: weight), points: [p(1, 1), p(2, 0)])
            }
        }
        let limited = try StrokeDashOutput(budget: &setup, limits: StrokeBackendLimits(maximumMagnitude: 1))
        #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeMagnitude")) {
            try limited.append(.move, points: [p(2, 0)])
        }
    }

    /// 初始化失败仍向调用方留下已耗工作；增长超限不会被解释成成功前缀。
    @Test func initializationAndGrowthKeepFailureCosts() throws {
        var tiny = try GeometryBudget(maximumBytes: 127)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            _ = try StrokeDashOutput(budget: &tiny, limits: .standard)
        }
        #expect(tiny.work == 1)
        var budget = try GeometryBudget(maximumBytes: 200)
        let output = try StrokeDashOutput(budget: &budget, limits: .standard)
        try output.append(.move, points: [.zero])
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try output.append(.quad, points: [p(1, 1), p(2, 0)])
        }
        #expect(output.budget.work == 3)
        var roomy = try GeometryBudget()
        let limited = try StrokeDashOutput(budget: &roomy, limits: StrokeBackendLimits(maximumOutputElements: 1))
        try limited.append(.move, points: [.zero])
        #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeOutputElements")) { try limited.appendZeroLengthLine() }
    }

    /// 发布StrokePath会再次计入完整模型保活成本，不能借用builder已付成本跳过验证。
    @Test func publicationChargesRetainedModel() throws {
        var budget = try GeometryBudget(maximumBytes: 300)
        let output = try StrokeDashOutput(budget: &budget, limits: .standard)
        try output.append(.move, points: [.zero])
        try output.append(.line, points: [p(1, 0)])
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) { try output.finish() }
        #expect(output.budget.work == 4)
    }

    /// 成功写入前缀后取消，最终发布仍传播取消，不把已有数组交给调用方。
    @Test func cancellationPreventsPublishingPrefix() async throws {
        let task = Task {
            var budget = try GeometryBudget()
            let output = try StrokeDashOutput(budget: &budget, limits: .standard)
            try output.append(.move, points: [.zero])
            try output.append(.line, points: [p(1, 0)])
            withUnsafeCurrentTask { $0?.cancel() }
            return try output.finish()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 简写纯语义坐标，保留测试指定的Double精度。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }
}
