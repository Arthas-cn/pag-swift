import Testing
@testable import pag_swift

/// 原曲线全局参数、退化切线和尖点检测的独立手算参照，不构造PAG字节。
struct StrokeCubicSamplingTests {
    /// 无/单/双/重根拐点直接用二次开区间根，不能按局部Cubic重参数化。
    @Test func inflectionsKeepGlobalParameters() throws {
        let cases: [([SIMD2<Float>], [Float])] = [
            ([.zero, SIMD2(0, 4), SIMD2(4, 4), SIMD2(4, 0)], []),
            ([.zero, SIMD2(2, 2), SIMD2(2, -2), SIMD2(4, 0)], [0.5]),
            ([.zero, SIMD2(1, 0), SIMD2(1, 3), SIMD2(0, -7)], [0.25, 0.75]),
            ([.zero, SIMD2(4, 4), SIMD2(0, 4), SIMD2(4, 0)], [0.5])
        ]
        for (points, expected) in cases {
            var budget = try GeometryBudget()
            #expect(try StrokeCubicSampling.inflections(points, budget: &budget) == expected)
        }
        // 极小但非零二次首项仍保留两个根；不能套用三次方程的绝对降阶阈值。
        var budget = try GeometryBudget()
        let scale: Float = 1.0 / 1_048_576
        #expect(try StrokeCubicPolynomial.quadraticRoots(16 * scale, -16 * scale, 3 * scale, budget: &budget) == [0.25, 0.75])
    }

    /// 尖点处两侧都借原曲线左半恢复向上切线；普通凸拱则沿向右切线。
    @Test func midpointRayUsesOriginalCubicAndAbsoluteTangentPoint() throws {
        let cusp: [SIMD2<Float>] = [.zero, SIMD2(4, 4), SIMD2(0, 4), SIMD2(4, 0)]
        let arch: [SIMD2<Float>] = [.zero, SIMD2(0, 4), SIMD2(4, 4), SIMD2(4, 0)]
        var budget = try GeometryBudget()
        for side: Float in [1, -1] {
            let a = try StrokeCubicSampling.ray(cusp, at: 0.5, radius: 2, side: side, budget: &budget)
            #expect(a.curve == SIMD2(2, 3))
            #expect(a.offset == SIMD2(2 + 2 * side, 3))
            #expect(a.tangent == SIMD2(2 + 2 * side, 5))
            let b = try StrokeCubicSampling.ray(arch, at: 0.5, radius: 2, side: side, budget: &budget)
            #expect(b.offset == SIMD2(2, 3 - 2 * side))
            #expect(b.tangent == SIMD2(4, 3 - 2 * side))
        }
    }

    /// 精确端控制点重复时依次补下一个控制点/弦；内部末级回退必须用左半弦。
    @Test func zeroDerivativesPreserveSourceFallbackOrder() throws {
        var budget = try GeometryBudget()
        let start: [SIMD2<Float>] = [.zero, .zero, .zero, SIMD2(0, 4)]
        let end: [SIMD2<Float>] = [.zero, SIMD2(4, 0), SIMD2(4, 3), SIMD2(4, 3)]
        let folded: [SIMD2<Float>] = [SIMD2(-1, 0), SIMD2(1, 0), SIMD2(-1, 0), SIMD2(1, 0)]
        #expect(try StrokeCubicSampling.ray(start, at: 0, radius: 2, side: 1, budget: &budget).offset == SIMD2(2, 0))
        #expect(try StrokeCubicSampling.ray(end, at: 1, radius: 2, side: 1, budget: &budget).offset == SIMD2(6, 3))
        #expect(try StrokeCubicSampling.ray(folded, at: 0.5, radius: 2, side: 1, budget: &budget).offset == SIMD2(0, -2))
        let point = Array(repeating: SIMD2<Float>(3, 4), count: 4)
        #expect(try StrokeCubicSampling.ray(point, at: 0.5, radius: 2, side: -1, budget: &budget).offset == SIMD2(3, 6))
    }

    /// Float长度平方下溢不等于零切线，Double setLength仍能得到竖向半径。
    @Test func tinyDerivativeSurvivesNormalization() throws {
        let tiny = Float(sign: .plus, exponent: -100, significand: 1)
        let points: [SIMD2<Float>] = [.zero, SIMD2(0, tiny), SIMD2(0, tiny * 2), SIMD2(0, tiny * 3)]
        var budget = try GeometryBudget()
        #expect(tiny * tiny == 0)
        let ray = try StrokeCubicSampling.ray(points, at: 0, radius: 2, side: 1, budget: &budget)
        #expect(ray.offset == SIMD2(2, 0))
        #expect(ray.tangent == SIMD2(2, 2))
    }

    /// 尖点圆心由实际曲率根的Horner值决定，不能吸附到拐点；交叉控制边也不必然有cusp。
    @Test func cuspUsesUnrepairedDerivativeAndFirstCurvatureRoot() throws {
        var budget = try GeometryBudget()
        let points: [SIMD2<Float>] = [.zero, SIMD2(4, 4), SIMD2(0, 4), SIMD2(4, 0)]
        let parameter = try #require(StrokeCubicSampling.cusp(points, budget: &budget))
        #expect(parameter == Float(0.5).nextUp)
        let center = try StrokeCubicAnalysis.position(points, at: parameter)
        #expect(center == SIMD2(Float(2).nextUp, Float(3).nextDown))
        #expect(try StrokeCubicSampling.cusp([.zero, SIMD2(4, 4), SIMD2(0, 4), SIMD2(5, 0)], budget: &budget) == nil)
        #expect(try StrokeCubicSampling.cusp([.zero, .zero, SIMD2(4, 4), SIMD2(4, 0)], budget: &budget) == nil)
    }

    /// 叉积乘积下溢到负零时按源on_same_side拒绝，不能以符号异或恢复理想交叉。
    @Test func cuspCrossProductUnderflowRejects() throws {
        var budget = try GeometryBudget()
        let scale: Float = 1e-12
        let points: [SIMD2<Float>] = [.zero, SIMD2(4 * scale, 4 * scale), SIMD2(0, 4 * scale), SIMD2(4 * scale, 0)]
        #expect(try StrokeCubicSampling.cusp(points, budget: &budget) == nil)
    }

    /// 无效参数、不可表示坐标及预算/取消在返回ray之前失败，不返回伪造零向量。
    @Test func samplingFailuresRemainExplicit() async throws {
        var budget = try GeometryBudget()
        let points = Array(repeating: SIMD2<Float>.zero, count: 4)
        #expect(throws: PAGError.invalidArgument("strokeCubicSampling")) {
            try StrokeCubicSampling.ray(points, at: 0.5, radius: 1, side: 0, budget: &budget)
        }
        #expect(throws: PAGError.invalidArgument("strokeCubicPoints")) {
            try StrokeCubicSampling.inflections([], budget: &budget)
        }
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try StrokeCubicSampling.ray(Array(repeating: SIMD2<Float>(.infinity, 0), count: 4), at: 0, radius: 1, side: 1, budget: &budget)
        }
        var work = try GeometryBudget(maximumWork: 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try StrokeCubicSampling.cusp(points, budget: &work)
        }
        let task = Task {
            var local = try GeometryBudget()
            withUnsafeCurrentTask { $0?.cancel() }
            return try StrokeCubicSampling.ray(points, at: 0.5, radius: 1, side: 1, budget: &local)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
