import Testing
@testable import pag_swift

/// 扫描事件量化的独立数值反例；不以提高固定x容差掩盖真实顺序错误。
struct ScanBoundaryTests {
    /// list/19第1帧的真实两边反序36个x ULP，但精确交点在相邻y之间，必须接纳。
    @Test func steepIntersectionUsesHeightCertificate() throws {
        let left = ScanBoundary(ScenePoint(x: 9.39033699035644, y: 414.34999084472656),
                                ScenePoint(x: 203.04033851623535, y: 414.8829803466797))
        let right = ScanBoundary(ScenePoint(x: 204.14853858947754, y: 414.83282470703125),
                                 ScenePoint(x: 203.03997230529785, y: 414.8829803466797))
        let y = 414.8829793965449
        #expect(left.x(at: y) - right.x(at: y) > max(left.x(at: y).ulp, right.x(at: y).ulp) * 32)
        var budget = try GeometryBudget()
        let result = try ScanBoundary.ordered(left, right, at: y, budget: &budget)
        #expect(result.0 == result.1)
        // 独立Fraction计算的交点x为203.03999330567595附近，非生产器反推的期望。
        #expect(abs(result.0 - 203.03999330567595) < 1e-12)
        #expect(budget.work == 64)
    }

    /// 精确交点1−2^-54不能表示为Double；整条带仍保留，接近端点的小瓣只发生局部量化。
    @Test(arguments: [false, true])
    func intersectionRoundedToEndpointKeepsMainArea(_ reversed: Bool) throws {
        let epsilon = Double(sign: .plus, exponent: -54, significand: 1)
        let contour = [ScenePoint(x: 1, y: 0), ScenePoint(x: 0, y: 1),
                       ScenePoint(x: epsilon, y: 1), ScenePoint(x: epsilon, y: 0)]
        let mesh = try GeometryTestSupport.mesh([reversed ? contour.reversed() : contour])
        let expected = ((1 - epsilon) * (1 - epsilon) + epsilon * epsilon) / 2
        #expect(abs(GeometryTestSupport.area(mesh) - expected) <= Double.ulpOfOne)
        #expect(GeometryTestSupport.coverage(mesh, at: ScenePoint(x: 0.5, y: 0.25)) == 1)
        #expect(GeometryTestSupport.coverage(mesh, at: ScenePoint(x: 0.75, y: 0.5)) == 0)
    }

    /// 两条同向陡平行边各自x范围可重叠，仍没有同y交点证书，必须拒绝错排。
    @Test func overlappingRangesDoNotCertifyParallelEdges() throws {
        let left = ScanBoundary(ScenePoint(x: 0, y: 0), ScenePoint(x: 2e16, y: 2))
        let right = ScanBoundary(ScenePoint(x: -4, y: 0), ScenePoint(x: 2e16 - 4, y: 2))
        var budget = try GeometryBudget()
        #expect(throws: PAGError.renderingFailure("geometryOrdering")) {
            try ScanBoundary.ordered(left, right, at: 1, budget: &budget)
        }
    }

    /// 位于带内部且远离相邻y的真实交叉不能折叠到当前边界，错误仍向上传播。
    @Test func distantCrossingIsNotBoundaryQuantization() throws {
        let left = ScanBoundary(ScenePoint(x: 1, y: 0), ScenePoint(x: 0, y: 1))
        let right = ScanBoundary(ScenePoint(x: 0, y: 0), ScenePoint(x: 1, y: 1))
        var budget = try GeometryBudget()
        #expect(throws: PAGError.renderingFailure("geometryOrdering")) {
            try ScanBoundary.ordered(left, right, at: 0.25, budget: &budget)
        }
    }

    /// 区间舍入过宽的两处真实反例用精确符号判定，期望来自独立有理数计算。
    @Test func exactFallbackResolvesUncertainIntervals() throws {
        let pairs: [(ScanBoundary, ScanBoundary, Double, Int)] = [
            (ScanBoundary(ScenePoint(x: 8.25, y: 0.6000003814697266),
                          ScenePoint(x: 6.657812479883432, y: 0.9914064705371857)),
             ScanBoundary(ScenePoint(x: 7.398437492549419, y: 0.8648438304662704),
                          ScenePoint(x: 4.700000047683716, y: 1.1999998092651367)), 0.9215250281406286, -1),
            (ScanBoundary(ScenePoint(x: 11, y: 0), ScenePoint(x: 2, y: 20)),
             ScanBoundary(ScenePoint(x: 1, y: 4), ScenePoint(x: 13, y: 16)), 9.655172413793103, 1)
        ]
        for (left, right, y, lowSign) in pairs {
            var budget = try GeometryBudget()
            #expect(try ScanExactSign.difference(left, right, at: y.nextDown, budget: &budget) == lowSign)
            #expect(try ScanExactSign.difference(left, right, at: y.nextUp, budget: &budget) == -lowSign)
            let result = try ScanBoundary.ordered(left, right, at: y, budget: &budget)
            #expect(result.0 == result.1)
            #expect(budget.work > 64)
        }
    }

    /// 精确相交与同线返回零；极小乘积的FMA余项不能表示时明确拒绝，不能伪称精确。
    @Test func exactSignPreservesZeroAndRejectsLostProductBits() throws {
        let left = ScanBoundary(ScenePoint(x: 0, y: 0), ScenePoint(x: 1, y: 1))
        let right = ScanBoundary(ScenePoint(x: 1, y: 0), ScenePoint(x: 0, y: 1))
        var budget = try GeometryBudget()
        #expect(try ScanExactSign.difference(left, right, at: 0.5, budget: &budget) == 0)
        #expect(try ScanExactSign.difference(left, left, at: 0.371, budget: &budget) == 0)
        let x = Double(sign: .plus, exponent: -500, significand: 1.0.nextUp)
        let y = Double(sign: .plus, exponent: -522, significand: 1.0.nextUp)
        let tinyLeft = ScanBoundary(ScenePoint(x: x, y: 0), ScenePoint(x: 0, y: y))
        let tinyRight = ScanBoundary(ScenePoint(x: 0, y: 0), ScenePoint(x: x, y: y))
        #expect(throws: PAGError.renderingFailure("geometryOrdering")) {
            try ScanExactSign.difference(tinyLeft, tinyRight, at: y * 0.5, budget: &budget)
        }
    }

    /// 大数相消、完全相消及单个最低有效位均须保留精确符号；独立Fraction期望不依赖展开存储。
    @Test func exactExpansionPreservesCancellationResiduals() throws {
        let cases: [(ScanBoundary, ScanBoundary, Double, Int)] = [
            (ScanBoundary(.zero, ScenePoint(x: 1.0.nextUp, y: 1)),
             ScanBoundary(ScenePoint(x: 1, y: 0), ScenePoint(x: 0, y: 1)), 0.5, 1),
            (ScanBoundary(ScenePoint(x: 1e15, y: 0), ScenePoint(x: 1e15 + 1, y: 3)),
             ScanBoundary(ScenePoint(x: 1e15 + 0.5, y: 0), ScenePoint(x: 1e15 - 0.5, y: 3)), 0.75, 0),
            (ScanBoundary(ScenePoint(x: -1e15, y: -3), ScenePoint(x: -1e15 + 1, y: 1)),
             ScanBoundary(ScenePoint(x: -1e15 + 0.5, y: -2), ScenePoint(x: -1e15 - 0.5, y: 1)), -2, -1)
        ]
        // 三处精确插值差依次为2^-53、0和−1/4；交换操作数必须得到相反符号。
        for (left, right, y, expected) in cases {
            var budget = try GeometryBudget()
            #expect(try ScanExactSign.difference(left, right, at: y, budget: &budget) == expected)
            #expect(try ScanExactSign.difference(right, left, at: y, budget: &budget) == -expected)
        }
    }

    /// 冷分支工作不足或已取消时不得返回合并端点；正常顺序仍保持零额外工作。
    @Test func certificateRespectsBudgetAndCancellation() async throws {
        let left = ScanBoundary(ScenePoint(x: 1, y: 0), ScenePoint(x: 1, y: 1))
        let right = ScanBoundary(ScenePoint(x: 0, y: 0), ScenePoint(x: 0, y: 1))
        var budget = try GeometryBudget(maximumWork: 63)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try ScanBoundary.ordered(left, right, at: 0.5, budget: &budget)
        }
        _ = try ScanBoundary.ordered(right, left, at: 0.5, budget: &budget)
        #expect(budget.work == 0)
        let task = Task {
            var budget = try GeometryBudget()
            withUnsafeCurrentTask { $0?.cancel() }
            return try ScanBoundary.ordered(left, right, at: 0.5, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 固定区间成本已经支付后，精确展开的临时存储和逐项工作仍受独立上限约束。
    @Test func exactFallbackChargesTemporaryArraysAndWork() throws {
        let left = ScanBoundary(ScenePoint(x: 11, y: 0), ScenePoint(x: 2, y: 20))
        let right = ScanBoundary(ScenePoint(x: 1, y: 4), ScenePoint(x: 13, y: 16))
        let y = 9.655172413793103
        var bytes = try GeometryBudget(maximumBytes: 16)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try ScanBoundary.ordered(left, right, at: y, budget: &bytes)
        }
        #expect(bytes.work > 64)
        var work = try GeometryBudget(maximumWork: 65)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try ScanBoundary.ordered(left, right, at: y, budget: &work)
        }
        #expect(work.work == 65)
    }
}
