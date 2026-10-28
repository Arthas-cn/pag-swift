import Testing
@testable import pag_swift

/// 文字选择器的逐字形因子、上游叠加次序及局部随机状态。
struct TextAnimatorSelectorsTests {
    /// 没有选择器时所有字形受完整动画值影响，空文本不分配因子。
    @Test func noSelectorMeansFullFactor() throws {
        var budget = FramePlanBudget(limit: 4096)
        #expect(try TextAnimatorSelectors.factors([], count: 3, at: 0, budget: &budget) == [1, 1, 1])
        #expect(try TextAnimatorSelectors.factors([], count: 0, at: 0, budget: &budget).isEmpty)
    }

    /// 方形范围只覆盖相交字形，第二个Subtract在首次因子基础上扣除。
    @Test func squareAndSubtractPreserveSelectorOrder() throws {
        let first = range(start: 0, end: 0.5)
        let second = range(start: 0, end: 0.5, mode: 2)
        var budget = FramePlanBudget(limit: 16_384)
        let factors = try TextAnimatorSelectors.factors([.range(first), .range(second)],
            count: 4, at: 0, budget: &budget)
        #expect(factors == [0, 0, 0, 0])
    }

    /// 随机排序与Darwin rand的零种子首字形修正一致，不改写全局随机状态。
    @Test func randomOrderUsesLocalSourceSequence() throws {
        let selector = range(start: 0, end: 1, shape: 1, random: true)
        var budget = FramePlanBudget(limit: 16_384)
        let factors = try TextAnimatorSelectors.factors([.range(selector)], count: 5, at: 0, budget: &budget)
        for (actual, expected) in zip(factors, [Float(0.9), 0.3, 0.1, 0.5, 0.7]) {
            #expect(abs(actual - expected) < 0.00001)
        }
    }

    /// 三角形高低缓和与平滑轮廓均随中心字形变化，端点外保持零。
    @Test func triangleAndSmoothHaveDistinctProfiles() throws {
        let triangle = range(start: 0, end: 1, shape: 3)
        let smooth = range(start: 0, end: 1, shape: 5)
        var budget = FramePlanBudget(limit: 16_384)
        let first = try TextAnimatorSelectors.factors([.range(triangle)], count: 5, at: 0, budget: &budget)
        let second = try TextAnimatorSelectors.factors([.range(smooth)], count: 5, at: 0, budget: &budget)
        #expect(first[2] > first[0] && first[2] > first[4])
        #expect(second[2] > second[0] && second[2] > second[4])
        #expect(first != second)
    }

    /// 因子数量在分配前计费，限额不足不能返回部分数组。
    @Test func factorBudgetRejectsBeforeAllocation() {
        var budget = FramePlanBudget(limit: 8)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try TextAnimatorSelectors.factors([], count: 100, at: 0, budget: &budget)
        }
    }

    /// 构造单个方形或指定形状的静态范围，除变更项外采用TextSelector.cpp默认值。
    private func range(start: Double, end: Double, mode: UInt8 = 1, shape: UInt8 = 0,
                       random: Bool = false) -> SourceTextRangeSelector {
        SourceTextRangeSelector(start: SourceProperty(constant: start), end: SourceProperty(constant: end),
            offset: SourceProperty(constant: 0), units: 0, basedOn: 0,
            mode: SourceProperty(constant: mode), amount: SourceProperty(constant: 1), shape: shape,
            smoothness: SourceProperty(constant: 1), easeHigh: SourceProperty(constant: 0),
            easeLow: SourceProperty(constant: 0), randomizeOrder: random,
            randomSeed: SourceProperty(constant: 0))
    }
}
