import Testing
@testable import pag_swift

/// Quad/Conic原参数射线的独立Float参照，覆盖方向回退、半径舍入及失败，不测试轮廓拼接。
struct StrokeQuadraticSamplingTests {
    /// 普通拱中点沿水平切线偏移，tangent保存绝对点而非方向向量，两侧共享曲线位置。
    @Test func quadMidpointUsesAbsoluteTangentPoints() throws {
        let curve = try StrokeQuadCurve(start: .zero, control: SIMD2(1, 1), end: SIMD2(2, 0))
        var budget = try GeometryBudget()
        for side: Float in [1, -1] {
            let ray = try StrokeQuadraticSampling.ray(curve, at: 0.5, radius: 2, side: side, budget: &budget)
            #expect(ray.curve == SIMD2(1, 0.5))
            #expect(ray.offset == SIMD2(1, 0.5 - 2 * side))
            #expect(ray.tangent == SIMD2(3, 0.5 - 2 * side))
        }
    }

    /// quarter按原有理Horner位置和切线采样；单位半径内侧在中点恰好收缩到原点。
    @Test func conicMidpointKeepsRationalSampling() throws {
        let curve = try quarter()
        var budget = try GeometryBudget()
        let outer = try StrokeQuadraticSampling.ray(curve, at: 0.5, radius: 1, side: 1, budget: &budget)
        #expect(outer.curve == bits(0x3F3504F3, 0x3F3504F3))
        #expect(outer.offset == bits(0x3FB504F3, 0x3FB504F3))
        #expect(outer.tangent == bits(0x3F3504F3, 0x4007C3B6))
        let inner = try StrokeQuadraticSampling.ray(curve, at: 0.5, radius: 1, side: -1, budget: &budget)
        #expect(inner.curve == outer.curve)
        #expect(inner.offset == .zero)
        #expect(inner.tangent == bits(0xBF3504F3, 0x3F3504F3))
    }

    /// 内部恰零导数只借原首末弦；Quad和Conic的不同控制值都在t=0.75产生同一竖向回退。
    @Test func zeroInteriorDirectionsUseTheOriginalChord() throws {
        var budget = try GeometryBudget()
        let quad = try StrokeQuadCurve(start: .zero, control: SIMD2(0, 3), end: SIMD2(0, 2))
        let conic = try StrokeConicCurve(start: .zero, control: SIMD2(0, 3.75), end: SIMD2(0, 2), weight: 0.5)
        let rays = [
            try StrokeQuadraticSampling.ray(quad, at: 0.75, radius: 2, side: 1, budget: &budget),
            try StrokeQuadraticSampling.ray(conic, at: 0.75, radius: 2, side: 1, budget: &budget)
        ]
        for ray in rays {
            #expect(ray.curve == SIMD2(0, 2.25))
            #expect(ray.offset == SIMD2(2, 2.25))
            #expect(ray.tangent == SIMD2(2, 4.25))
        }
    }

    /// 首末弦也为零时选默认横轴，不能仿照Cubic借左半控制边修补方向。
    @Test func zeroDirectionAndChordUseTheDefaultAxis() throws {
        var budget = try GeometryBudget()
        let folded = try StrokeQuadCurve(start: .zero, control: SIMD2(0, 4), end: .zero)
        let ray = try StrokeQuadraticSampling.ray(folded, at: 0.5, radius: 2, side: 1, budget: &budget)
        #expect(ray.curve == SIMD2(0, 2))
        #expect(ray.offset == .zero)
        #expect(ray.tangent == SIMD2(2, 0))
        let point = try StrokeConicCurve(start: SIMD2(3, 4), control: SIMD2(3, 4), end: SIMD2(3, 4), weight: 0.5)
        let still = try StrokeQuadraticSampling.ray(point, at: 0.5, radius: 2, side: -1, budget: &budget)
        #expect(still.curve == SIMD2(3, 4))
        #expect(still.offset == SIMD2(3, 6))
        #expect(still.tangent == SIMD2(5, 6))
    }

    /// 端控制点重复使用首末弦；极小非零导数仍由Double setLength保留竖向，不能按平方长度视为零。
    @Test func repeatedEndpointsAndTinyDirectionsKeepTheirOrientation() throws {
        var budget = try GeometryBudget()
        let end = SIMD2<Float>(0, 4)
        for atStart in [true, false] {
            let quad = try StrokeQuadCurve(start: .zero, control: atStart ? .zero : end, end: end)
            let conic = try StrokeConicCurve(start: .zero, control: atStart ? .zero : end, end: end, weight: 0.5)
            let parameter: Float = atStart ? 0 : 1
            let expected = SIMD2<Float>(2, atStart ? 0 : 4)
            #expect(try StrokeQuadraticSampling.ray(quad, at: parameter, radius: 2, side: 1, budget: &budget).offset == expected)
            #expect(try StrokeQuadraticSampling.ray(conic, at: parameter, radius: 2, side: 1, budget: &budget).offset == expected)
        }
        let tiny = Float(sign: .plus, exponent: -100, significand: 1)
        let small = try StrokeQuadCurve(start: .zero, control: SIMD2(0, tiny), end: SIMD2(0, 2 * tiny))
        #expect(tiny * tiny == 0)
        let ray = try StrokeQuadraticSampling.ray(small, at: 0, radius: 2, side: 1, budget: &budget)
        #expect(ray.offset == SIMD2(2, 0))
        #expect(ray.tangent == SIMD2(2, 2))
    }

    /// 非有限原方向不借有限竖向弦，而是让setLength失败并选择横轴；位置有限时不能提前报错。
    @Test func nonfiniteDirectionsKeepTheSourceDefaultFallback() throws {
        var budget = try GeometryBudget()
        let conic = try StrokeConicCurve(start: SIMD2(0, -2), control: SIMD2(1, 0), end: SIMD2(0, 2),
                                        weight: Float(sign: .plus, exponent: 126, significand: 1))
        // 独立源公式得到位置(1,0)、方向(0,NaN)；竖向弦若被错误使用，offset会变成(3,0)。
        let rational = try StrokeQuadraticSampling.ray(conic, at: 0.5, radius: 2, side: 1, budget: &budget)
        #expect(rational.curve == SIMD2(1, 0))
        #expect(rational.offset == SIMD2(1, -2))
        #expect(rational.tangent == SIMD2(3, -2))
        let quad = try StrokeQuadCurve(start: .zero, control: .zero, end: SIMD2(0, .greatestFiniteMagnitude))
        let ordinary = try StrokeQuadraticSampling.ray(quad, at: 1, radius: 1, side: 1, budget: &budget)
        #expect(ordinary.curve == SIMD2(0, .greatestFiniteMagnitude))
        #expect(ordinary.offset == SIMD2(0, .greatestFiniteMagnitude))
        #expect(ordinary.tangent == SIMD2(1, .greatestFiniteMagnitude))
    }

    /// 半径1.3应直接进入Double setLength；先Float单位化再相乘会把两个分量都降低一位。
    @Test func radiusIsAppliedInTheSingleNormalizationStep() throws {
        var budget = try GeometryBudget()
        let quad = try StrokeQuadCurve(start: .zero, control: SIMD2(1, 1), end: SIMD2(2, 0))
        let conic = try StrokeConicCurve(start: .zero, control: SIMD2(1, 1), end: SIMD2(2, 0), weight: 0.5)
        let radius = Float(bitPattern: 0x3FA66666)
        let rays = [
            try StrokeQuadraticSampling.ray(quad, at: 0, radius: radius, side: 1, budget: &budget),
            try StrokeQuadraticSampling.ray(conic, at: 0, radius: radius, side: 1, budget: &budget)
        ]
        for ray in rays {
            // 独立binary32/Double探针：直接缩放为0x3F6B533C，先单位化则为0x3F6B533B。
            #expect(ray.offset == bits(0x3F6B533C, 0xBF6B533C))
            #expect(ray.tangent == bits(0x3FEB533C, 0))
        }
    }

    /// t=1也保留各自Horner位置；ray不得吸附到存储终点或依据存储终点重建位置。
    @Test func endpointRaysPreserveHornerRounding() throws {
        var budget = try GeometryBudget()
        let quad = try StrokeQuadCurve(start: SIMD2(16_777_216, 0), control: .zero, end: SIMD2(1, 0))
        let ordinary = try StrokeQuadraticSampling.ray(quad, at: 1, radius: 1, side: 1, budget: &budget)
        #expect(ordinary.curve == .zero)
        #expect(ordinary.offset == SIMD2(0, 1))
        #expect(ordinary.tangent == SIMD2(-1, 1))
        let conic = try StrokeConicCurve(start: .zero, control: SIMD2(0.25, 0), end: SIMD2(-0.25, 0),
                                        weight: Float(bitPattern: 0x3F3504F3))
        let rational = try StrokeQuadraticSampling.ray(conic, at: 1, radius: 1, side: 1, budget: &budget)
        #expect(rational.curve == bits(0xBE800001, 0))
        #expect(rational.offset == bits(0xBE800001, 0x3F800000))
    }

    /// 参数、半径和侧别有各自合法范围，但两种曲线采样入口统一报告strokeQuadraticSampling。
    @Test func invalidSamplingArgumentsFailBeforeEvaluation() throws {
        let quad = try StrokeQuadCurve(start: .zero, control: SIMD2(1, 1), end: SIMD2(2, 0))
        let conic = try quarter()
        let invalid: [(Float, Float, Float)] = [
            (-0.1, 1, 1), (Float(1).nextUp, 1, 1), (.nan, 1, 1), (.infinity, 1, 1),
            (0.5, 0, 1), (0.5, -1, 1), (0.5, .nan, 1), (0.5, .infinity, 1),
            (0.5, 1, 0), (0.5, 1, 0.5), (0.5, 1, .nan), (0.5, 1, .infinity)
        ]
        for (parameter, radius, side) in invalid {
            var budget = try GeometryBudget()
            #expect(throws: PAGError.invalidArgument("strokeQuadraticSampling")) {
                try StrokeQuadraticSampling.ray(quad, at: parameter, radius: radius, side: side, budget: &budget)
            }
            #expect(throws: PAGError.invalidArgument("strokeQuadraticSampling")) {
                try StrokeQuadraticSampling.ray(conic, at: parameter, radius: radius, side: side, budget: &budget)
            }
        }
    }

    /// 位置系数、偏移点和绝对切线点不可表示均报精度失败，不能把方向回退扩展为任意数值修补。
    @Test func nonrepresentableRayPointsFailExplicitly() throws {
        var budget = try GeometryBudget()
        let limit = Float.greatestFiniteMagnitude
        let coefficient = try StrokeQuadCurve(start: .zero, control: SIMD2(limit, 0), end: .zero)
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try StrokeQuadraticSampling.ray(coefficient, at: 0.5, radius: 1, side: 1, budget: &budget)
        }
        let vertical = try StrokeQuadCurve(start: .zero, control: .zero, end: SIMD2(0, limit))
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try StrokeQuadraticSampling.ray(vertical, at: 1, radius: limit, side: -1, budget: &budget)
        }
        let horizontal = try StrokeQuadCurve(start: .zero, control: .zero, end: SIMD2(limit, 0))
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try StrokeQuadraticSampling.ray(horizontal, at: 1, radius: limit, side: 1, budget: &budget)
        }
        let rational = try quarter(weight: limit)
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try StrokeQuadraticSampling.ray(rational, at: 0.5, radius: 1, side: 1, budget: &budget)
        }
    }

    /// ray入口、位置和方向共享工作预算，已取消任务在读取曲线之前失败且不依赖调度时机。
    @Test func workAndCancellationBoundEverySamplingStage() async throws {
        let quad = try StrokeQuadCurve(start: .zero, control: SIMD2(1, 1), end: SIMD2(2, 0))
        let conic = try quarter()
        var initial = try GeometryBudget(maximumWork: 31)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try StrokeQuadraticSampling.ray(quad, at: 0.5, radius: 1, side: 1, budget: &initial)
        }
        var direction = try GeometryBudget(maximumWork: 95)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try StrokeQuadraticSampling.ray(conic, at: 0.5, radius: 1, side: 1, budget: &direction)
        }
        #expect(direction.work == 64)
        for isConic in [false, true] {
            let task = Task {
                var local = try GeometryBudget()
                withUnsafeCurrentTask { $0?.cancel() }
                if isConic { return try StrokeQuadraticSampling.ray(conic, at: 0.5, radius: 1, side: 1, budget: &local) }
                return try StrokeQuadraticSampling.ray(quad, at: 0.5, radius: 1, side: 1, budget: &local)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }

    /// 单位quarter使用固定源码sqrt(2)/2的Float权重；参数仅用于数值失败夹具。
    private func quarter(weight: Float = Float(bitPattern: 0x3F3504F3)) throws -> StrokeConicCurve {
        try StrokeConicCurve(start: SIMD2(1, 0), control: SIMD2(1, 1), end: SIMD2(0, 1), weight: weight)
    }

    /// 载入独立源公式探针的位模式，不通过生产射线或曲线方法计算期望。
    private func bits(_ x: UInt32, _ y: UInt32) -> SIMD2<Float> { SIMD2(Float(bitPattern: x), Float(bitPattern: y)) }
}
