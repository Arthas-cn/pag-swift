import Testing
@testable import pag_swift

/// 源Conic的Float求值及两种截取算法，期望来自独立公式探针，不调用生产helper生成参照。
struct StrokeConicCurveTests {
    /// 有理位置与首末重复控制点切线各用对应源公式，不将有理方向当成完整导数归一化。
    @Test func positionsAndDegenerateTangentsFollowSource() throws {
        var budget = try GeometryBudget()
        #expect(try quarter().position(at: 0.5, budget: &budget) == bits(0x3F3504F3, 0x3F3504F3))
        for first in [true, false] {
            let end = SIMD2<Float>(3, 5)
            let value = try StrokeConicCurve(start: .zero, control: first ? .zero : end, end: end, weight: 0.3)
            #expect(try value.tangent(at: first ? 0 : 1, budget: &budget) == end)
        }
        let shifted = try StrokeConicCurve(start: .zero, control: SIMD2(4, 0), end: SIMD2(-4, 0), weight: Float(0.707106781))
        #expect(try shifted.position(at: 1, budget: &budget).x == -4.000000476837158)
        #expect(try shifted.segment(from: 0, to: 1, budget: &budget).end == SIMD2(-4, 0))
    }

    /// 单参数齐次切分在非半参数处保留独立控制点/权重，左右逐位共享一次投影中点。
    @Test func thirdSplitPreservesHomogeneousRounding() throws {
        var budget = try GeometryBudget()
        let curve = try quarter(), pair = try curve.split(at: Float(1) / 3, budget: &budget)
        #expect(pair.first.start == curve.start && pair.second.end == curve.end)
        #expect(pair.first.control == bits(0x3F800000, 0x3E85BC84))
        #expect(pair.first.end == bits(0x3F5F4C74, 0x3EFA63AC))
        #expect(pair.first.weight.bitPattern == 0x3F77B095)
        #expect(pair.second.start == pair.first.end)
        #expect(pair.second.control == bits(0x3F15F619, 0x3F800000))
        #expect(pair.second.weight.bitPattern == 0x3F5CE425)
        let left = try curve.segment(from: 0, to: Float(1) / 3, budget: &budget)
        let right = try curve.segment(from: Float(1) / 3, to: 1, budget: &budget)
        #expect(left.control == pair.first.control && left.end == pair.first.end && left.weight == pair.first.weight)
        #expect(right.start == pair.second.start && right.control == pair.second.control && right.weight == pair.second.weight)
    }

    /// 内部区间按原分子分母三点重建；不能复用Cubic的两次split和仿射重参数化。
    @Test func interiorSegmentUsesOriginalRationalParameters() throws {
        var budget = try GeometryBudget()
        let curve = try quarter(), middle = try curve.segment(from: 0.25, to: 0.75, budget: &budget)
        #expect(middle.start == bits(0x3F6E069B, 0x3EBC76E9))
        #expect(middle.control == bits(0x3F453E88, 0x3F453E88))
        #expect(middle.end == bits(0x3EBC76EB, 0x3F6E069C))
        #expect(middle.weight.bitPattern == 0x3F6AF123)
        let other = try curve.segment(from: Float(1) / 3, to: 0.8, budget: &budget)
        #expect(other.control == bits(0x3F2D2DBC, 0x3F5696DD))
        #expect(other.end == bits(0x3E966E84, 0x3F74B374))
        #expect(other.weight.bitPattern == 0x3F6DA995)
        // 重建中点舍入到起参数时仍走原公式；它不是偏移递归的进度检查。
        let adjacent = try curve.segment(from: 0.5, to: Float(0.5).nextUp, budget: &budget)
        #expect(adjacent.start == bits(0x3F3504F3, 0x3F3504F3))
        #expect(adjacent.control == bits(0x3F3504F5, 0x3F3504F3))
        #expect(adjacent.end == bits(0x3F3504F1, 0x3F3504F3) && adjacent.weight == 1)
    }

    /// 真实极短截取能舍入出单位权重，发布模型时才转Quad，不提前丢弃曲线控制点。
    @Test func shortSegmentReachesUnitWeight() throws {
        var budget = try GeometryBudget()
        let part = try quarter().segment(from: 0, to: 1.0 / 4096, budget: &budget)
        #expect(part.start == SIMD2(1, 0))
        #expect(part.control == SIMD2(1, 0.00017264584312215447))
        #expect(part.end == SIMD2(0.9999999403953552, 0.0003452916571404785))
        #expect(part.weight == 1)
        let points = [part.start, part.control, part.end].map { ScenePoint(x: Double($0.x), y: Double($0.y)) }
        let path = try StrokePath(verbs: [.move, .conic(weight: part.weight)], points: points, budget: &budget)
        #expect(path.verbs == [.move, .quad])
    }

    /// 极大正权重可使Horner失败而单参数切分成功；构造与整段快路不能急切计算系数。
    @Test func validSplitDoesNotDependOnHornerCoefficients() throws {
        let curve = try quarter(weight: .greatestFiniteMagnitude)
        var budget = try GeometryBudget()
        #expect(try curve.segment(from: 0, to: 1, budget: &budget).weight == .greatestFiniteMagnitude)
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) { try curve.position(at: 0.5, budget: &budget) }
        let pair = try curve.split(at: 0.5, budget: &budget)
        #expect(pair.first.control == SIMD2(1, 1) && pair.first.end == SIMD2(1, 1))
        #expect(pair.second.start == pair.first.end && pair.second.control == SIMD2(1, 1))
        #expect(pair.first.weight == Float(1.3043817602097349e19) && pair.second.weight == pair.first.weight)
    }

    /// 内部权重乘积溢出即使三个投影点有限也失败；正常权重乘法下溢仍可保留有效曲线。
    @Test func positiveWeightFailuresDoNotRejectHarmlessUnderflow() throws {
        var budget = try GeometryBudget()
        let huge = try quarter(weight: Float(sign: .plus, exponent: 80, significand: 1))
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) { try huge.segment(from: 0.25, to: 0.75, budget: &budget) }
        let tiny = try StrokeConicCurve(start: SIMD2(1, 0), control: SIMD2(0.5, 0.5), end: SIMD2(0, 1), weight: .leastNonzeroMagnitude)
        #expect(try tiny.position(at: 0.5, budget: &budget) == SIMD2(0.5, 0.5))
        #expect(try tiny.tangent(at: 0.5, budget: &budget) == SIMD2(-0.25, 0.25))
        let pair = try tiny.split(at: 0.5, budget: &budget)
        #expect(pair.first.weight == Float(0.707106781) && pair.second.weight == pair.first.weight)
    }

    /// 有限位置的非有限切线由后续ray决定默认方向，本层不得把方向溢出变成位置失败。
    @Test func rawTangentPreservesDirectionFallback() throws {
        let curve = try StrokeConicCurve(start: SIMD2(-2, 0), control: SIMD2(0, 1), end: SIMD2(2, 0),
                                        weight: Float(sign: .plus, exponent: 126, significand: 1))
        var budget = try GeometryBudget()
        #expect(try curve.position(at: 0.5, budget: &budget) == SIMD2(0, 1))
        let direction = try curve.tangent(at: 0.5, budget: &budget)
        #expect(direction.x.isNaN && direction.y == 0)
    }

    /// 非法点、权重、参数与零范围各保留对应失败原因，不输出空子曲线冒充成功。
    @Test func invalidInputsFailExplicitly() throws {
        for weight: Float in [0, -1, .nan, .infinity] {
            #expect(throws: PAGError.invalidArgument("strokeConicWeight")) { try quarter(weight: weight) }
        }
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try StrokeConicCurve(start: SIMD2(.infinity, 0), control: .zero, end: .zero, weight: 1)
        }
        let curve = try quarter()
        var budget = try GeometryBudget()
        for parameter: Float in [-1, .nan, .infinity] {
            #expect(throws: PAGError.invalidArgument("strokeCurveParameter")) { try curve.position(at: parameter, budget: &budget) }
        }
        for parameter: Float in [0, 1] {
            #expect(throws: PAGError.invalidArgument("strokeCurveParameter")) { try curve.split(at: parameter, budget: &budget) }
        }
        #expect(throws: PAGError.invalidArgument("strokeCurveRange")) { try curve.segment(from: 0.5, to: 0.5, budget: &budget) }
    }

    /// 分割或整段发布都受工作/字节预算约束，取消不因整段快路被绕过。
    @Test func budgetsAndCancellationPrecedeFastPaths() async throws {
        let curve = try quarter()
        var bytes = try GeometryBudget(maximumBytes: 255)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) { try curve.split(at: 0.5, budget: &bytes) }
        #expect(bytes.work == 64)
        var full = try GeometryBudget(maximumBytes: 127)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) { try curve.segment(from: 0, to: 1, budget: &full) }
        var work = try GeometryBudget(maximumWork: 31)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) { try curve.tangent(at: 0.5, budget: &work) }
        let task = Task {
            var budget = try GeometryBudget()
            withUnsafeCurrentTask { $0?.cancel() }
            return try curve.segment(from: 0, to: 1, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 单位四分圆控制点；默认权重是固定源码常量的Float值，允许测试替换极端正值。
    private func quarter(weight: Float = Float(0.707106781)) throws -> StrokeConicCurve {
        try StrokeConicCurve(start: SIMD2(1, 0), control: SIMD2(1, 1), end: SIMD2(0, 1), weight: weight)
    }

    /// 直接载入独立Float公式探针的位模式，不调用生产采样或截取方法。
    private func bits(_ x: UInt32, _ y: UInt32) -> SIMD2<Float> { SIMD2(Float(bitPattern: x), Float(bitPattern: y)) }
}
