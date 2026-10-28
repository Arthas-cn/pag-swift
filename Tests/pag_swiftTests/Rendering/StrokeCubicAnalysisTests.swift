import Testing
@testable import pag_swift

/// 固定Float求根与降阶分类的独立数值参照，不调用平台路径或生产求根器生成期望。
struct StrokeCubicAnalysisTests {
    /// 零至三根、重复根和三次端点钳制均按源码结果，不能只比较数学上的开区间根。
    @Test func polynomialRootCountsAndClamping() throws {
        let cases: [(SIMD4<Float>, [Float])] = [
            (SIMD4(0, 1, 0, 1), []), (SIMD4(0, 0, 2, -1), [0.5]),
            (SIMD4(0, 1, -1, 3.0 / 16), [0.25, 0.75]),
            (SIMD4(1, -1.5, 11.0 / 16, -3.0 / 32), [0.25, 0.5, 0.75]),
            (SIMD4(0, 1, -1, 0.25), [0.5]), (SIMD4(1, -1.5, 0.75, -0.125), [0.5]),
            (SIMD4(1, -1.5, 9.0 / 16, -1.0 / 16), [1]),
            (SIMD4(1, -1.5, -1.5, 1), [0, Float(0.5).nextUp, 1]),
            (SIMD4(1, 2.5, 0.5, -1), [0, Float(0.5).nextUp])
        ]
        for (coefficients, expected) in cases {
            var budget = try GeometryBudget()
            let actual = try StrokeCubicPolynomial.roots(coefficients, budget: &budget)
            #expect(actual == expected, "coefficients=\(coefficients), actual=\(actual.map(\.bitPattern)), expected=\(expected.map(\.bitPattern))")
        }
    }

    /// powf近似指数与绝对降阶阈值具有可观察Float位差，不能换成cbrt或先规范化系数。
    @Test func floatExponentAndAbsoluteThresholdArePreserved() throws {
        var budget = try GeometryBudget()
        let power = try StrokeCubicPolynomial.roots(SIMD4(1, 0, 0, -1.0 / 64), budget: &budget)
        #expect(power.map(\.bitPattern) == [0x3e800001])
        let threshold: Float = 1.0 / 4096
        #expect(try StrokeCubicPolynomial.roots(SIMD4(threshold, 0, 2, -1), budget: &budget) == [0.5])
        let adjacent = try StrokeCubicPolynomial.roots(SIMD4(threshold.nextUp, 0, 2, -1), budget: &budget)
        #expect(adjacent.map(\.bitPattern) == [0x3efffb00])
        let third = try StrokeCubicPolynomial.roots(SIMD4(0, 0, 3, -1), budget: &budget)
        #expect(third.map(\.bitPattern) == [0x3eaaaaab])
    }

    /// 位置按Float Horner求值；大控制点在t=1也可能不等于P3，不能补端点快捷路径。
    @Test func positionPreservesSourceHornerRounding() throws {
        let ordinary = try StrokeCubicAnalysis.position(points([0, 1, 2, 4]), at: Float(1) / 3)
        #expect(ordinary.x.bitPattern == 0x3f84bda2)
        let large = try StrokeCubicAnalysis.position(points([0, 16_777_216, 0, 1]), at: 1)
        #expect(large == .zero)
    }

    /// 三个相邻零向量为point，恰好两个为line；普通匀速共线Cubic没有额外转折。
    @Test func pointAndLineReductionsUseControlDegeneracy() throws {
        var budget = try GeometryBudget()
        if case .point = try StrokeCubicAnalysis.reduction(of: points([2, 2, 2, 2]), budget: &budget) {} else {
            Issue.record("全相等控制点应为point")
        }
        for values: [Float] in [[0, 0, 8, 8], [0, 1, 2, 3]] {
            if case .line = try StrokeCubicAnalysis.reduction(of: points(values), budget: &budget) {} else {
                Issue.record("此控制多边形应直接降成Line")
            }
        }
    }

    /// 一至三个内部F′·F″根形成源有序转折点，包含单调区间的速度极值而不限于真实回头点。
    @Test func collinearReductionsKeepAllSourceCurvaturePoints() throws {
        let cases: [([Float], [Float])] = [([0, 4, 4, 0], [3]), ([0, 5, -2, -5], [1.75, -2.25]),
                                          ([0, 4, -4, 8], [1.25, 1.125, 1])]
        for (values, expected) in cases {
            var budget = try GeometryBudget()
            guard case .polyline(let actual) = try StrokeCubicAnalysis.reduction(of: points(values), budget: &budget) else {
                Issue.record("应保留内部转折点"); continue
            }
            try #require(actual.count == expected.count)
            for (point, x) in zip(actual, expected) {
                #expect(abs(point.x - x) <= 0.000002)
                #expect(point.y == 0)
            }
        }
    }

    /// 近共线尺度阈值两侧分别进入降阶与真正Cubic；首控制点重复时非线性切向选P2。
    @Test func curvedAndNearlyLinearInputsRemainDistinct() throws {
        var budget = try GeometryBudget()
        for y: Float in [0.009, 0.01] {
            let value = try StrokeCubicAnalysis.reduction(of: [.zero, SIMD2(1, y), SIMD2(2, -y), SIMD2(3, 0)], budget: &budget)
            if case .curve = value { #expect(y == 0.01) } else { #expect(y == 0.009) }
        }
        let curve = try StrokeCubicAnalysis.reduction(of: [.zero, .zero, SIMD2(3, 4), SIMD2(10, 0)], budget: &budget)
        if case .curve(let tangent) = curve { #expect(tangent == SIMD2(3, 4)) }
        else { Issue.record("真正弯曲不能因首控制点重复变为Line") }
    }

    /// 有限接纳坐标也可能产生非有限求根中间量，应明确报精度失败，不能吞成零根/直线。
    @Test func invalidAndUnrepresentableAnalysisFailsExplicitly() throws {
        var budget = try GeometryBudget()
        #expect(throws: PAGError.invalidArgument("strokeCubicPoints")) {
            try StrokeCubicAnalysis.reduction(of: [.zero], budget: &budget)
        }
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try StrokeCubicAnalysis.reduction(of: points([0, 8_388_608, 8_388_608, 1]), budget: &budget)
        }
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try StrokeCubicPolynomial.roots(SIMD4(.nan, 0, 0, 0), budget: &budget)
        }
    }

    /// 求根与分类消耗同一工作/字节预算，取消发生在固定成本计算之前也必须传播。
    @Test func analysisHonorsBudgetsAndCancellation() async throws {
        var work = try GeometryBudget(maximumWork: 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try StrokeCubicAnalysis.reduction(of: points([0, 4, 4, 0]), budget: &work)
        }
        var bytes = try GeometryBudget(maximumBytes: 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try StrokeCubicPolynomial.roots(SIMD4(1, 0, 0, -1.0 / 64), budget: &bytes)
        }
        let task = Task {
            var budget = try GeometryBudget()
            withUnsafeCurrentTask { $0?.cancel() }
            return try StrokeCubicAnalysis.reduction(of: points([0, 4, 4, 0]), budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 构造手算的一维控制点，没有生成或声称合法的PAG二进制。
    private func points(_ x: [Float]) -> [SIMD2<Float>] { x.map { SIMD2($0, 0) } }
}
