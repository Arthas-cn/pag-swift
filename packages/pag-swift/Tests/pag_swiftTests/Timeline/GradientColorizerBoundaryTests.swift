import Testing
@testable import pag_swift

/// 渐变颜色程序的资源与失败语义，不把无法完成的编译降级成单色成功。
struct GradientColorizerBoundaryTests {
    /// 冷编译逐步计费且不回滚；精确预算可成功，少一字节不发布程序。
    @Test func coldCompilationHonorsExactBudget() throws {
        let source = GradientColorFixtures.colors(alpha: [(0, 0), (1, 255)], colorMidpoint: 0.25)
        var complete = FramePlanBudget(limit: 1_000_000)
        let program = try GradientColorizer.prepare(source, budget: &complete)
        #expect(complete.used >= program.estimatedBytes)
        var exact = FramePlanBudget(limit: complete.used)
        #expect(try GradientColorizer.prepare(source, budget: &exact).source === source)
        for limit in [0, 383, 640, 1000, complete.used - 1] {
            var budget = FramePlanBudget(limit: limit)
            #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
                try GradientColorizer.prepare(source, budget: &budget)
            }
            #expect(budget.used <= limit)
        }
    }

    /// 纯语义调用也不能绕过非空和4096限制；失败发生于计费前，不用短元数据触发巨量工作。
    @Test func invalidSemanticCountsFailBeforeCompilation() throws {
        let empty = GradientColorFixtures.colors(rgb: [])
        let huge = GradientColorFixtures.colors(rgb: (0...4096).map { (Float($0), GradientColorFixtures.red) })
        for source in [empty, huge] {
            var budget = FramePlanBudget(limit: 1_000_000)
            #expect(throws: PAGError.self) { try GradientColorizer.prepare(source, budget: &budget) }
            #expect(budget.used == 0)
        }
    }

    /// 无效源位置或中点不进入系数状态缓存；它们是原始颜色构造错误，必须立即失败。
    @Test func malformedSemanticStopsThrowImmediately() throws {
        for position: Float in [-1, .infinity, .nan] {
            let source = GradientColorFixtures.colors(rgb: [(position, GradientColorFixtures.red)])
            #expect(throws: PAGError.renderingFailure("gradientPrecision")) { try GradientColorFixtures.compile(source) }
        }
        for midpoint: Float in [-0.1, 1.1, .nan] {
            let source = GradientColorFixtures.colors(colorMidpoint: midpoint)
            #expect(throws: PAGError.unsupportedFeature("gradientMidpointRange")) { try GradientColorFixtures.compile(source) }
        }
    }

    /// 预取消在编译入口退出，不能以缓存失败状态代替CancellationError。
    @Test func cancellationDoesNotBecomeAColorizerState() async throws {
        let source = GradientColorFixtures.colors()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.cancelAll()
            group.addTask {
                var budget = FramePlanBudget(limit: 1_000_000)
                #expect(throws: CancellationError.self) { try GradientColorizer.prepare(source, budget: &budget) }
                #expect(budget.used == 0)
            }
            for try await _ in group {}
        }
    }
}
