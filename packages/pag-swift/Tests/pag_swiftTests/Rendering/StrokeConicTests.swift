import Foundation
import Testing
@testable import pag_swift

/// 用独立rational公式验证中心线转换，不使用CG或生产区间算法生成期望值。
struct StrokeConicTests {
    /// Float源码权重在通常、非均匀、剪切和高倍显示下均满足请求的位置误差份额。
    @Test func rationalPositionsRemainWithinTransformedTolerance() throws {
        let conic = quarter(radius: 32)
        let transforms = [SceneAffine.identity, try .scale(x: 37, y: 0.25),
            try SceneAffine(a: -4, b: 3, c: 7, d: 0.5, tx: 100, ty: -200), try .scale(x: 1_000_000, y: 1_000_000)]
        for transform in transforms {
            let segments = try approximate(conic, transform: transform)
            try verify(conic, segments: segments, transform: transform)
        }
    }

    /// 细分输出严格按参数顺序，左右复用同一端点，端点和内部切向不形成接缝。
    @Test func endpointsAndTangentContinuityArePreserved() throws {
        let conic = quarter(radius: 100)
        let segments = try approximate(conic, transform: .identity)
        #expect(segments.count > 1)
        #expect(segments.first?.start == conic.points[0] && segments.last?.end == conic.points[2])
        #expect(segments.first?.startParameter == 0 && segments.last?.endParameter == 1)
        #expect(segments.first?.first.x == conic.points[0].x && segments.last?.second.y == conic.points[2].y)
        for index in 1..<segments.count {
            let left = segments[index - 1], right = segments[index]
            #expect(left.end == right.start && left.endParameter == right.startParameter)
            let a = ScenePoint(x: left.end.x - left.second.x, y: left.end.y - left.second.y)
            let b = ScenePoint(x: right.first.x - right.start.x, y: right.first.y - right.start.y)
            #expect(abs(a.x * b.y - a.y * b.x) < 1e-9)
            #expect(a.x * b.x + a.y * b.y > 0)
        }
    }

    /// 非单位首末权重、反向与共线回折也保留原参数位置，不只适用于理想四分之一圆。
    @Test func unequalWeightsAndReversedCurvesUseOriginalParameters() throws {
        let curves = [
            StrokeConic(points: [.init(x: 10, y: 20), .init(x: -30, y: 40), .init(x: 50, y: -10)], weights: [2, 0.75, 3]),
            StrokeConic(points: [.init(x: 0, y: 1), .init(x: 1, y: 1), .init(x: 1, y: 0)], weights: [1, Double(Float(0.707106781)), 1]),
            StrokeConic(points: [.zero, .init(x: 100, y: 0), .init(x: 1, y: 0)], weights: [1, 4, 1])
        ]
        for conic in curves {
            try verify(conic, segments: approximate(conic, transform: .identity), transform: .identity)
        }
    }

    /// 同一曲线被放大时自动增加近似段；最终位置误差仍按变换后的坐标衡量。
    @Test func magnificationTightensSubdivision() throws {
        let conic = quarter(radius: 1)
        let scales = [1.0, 64, 4096, 1_048_576]
        var counts: [Int] = []
        for scale in scales {
            let matrix = try SceneAffine.scale(x: scale, y: scale)
            let segments = try approximate(conic, transform: matrix)
            counts.append(segments.count)
            try verify(conic, segments: segments, transform: matrix)
        }
        #expect(counts == counts.sorted() && counts.last ?? 0 > counts.first ?? 0)
    }

    /// 平移不进入误差放大，但候选控制点加回大原点的存储损失不能被局部验证掩盖。
    @Test func translatedCandidatesAreVerifiedAfterStorage() throws {
        let origin = 1_048_576.0
        let shifted = StrokeConic(points: [.init(x: origin + 32, y: origin), .init(x: origin + 32, y: origin + 32),
                                          .init(x: origin, y: origin + 32)], weights: [1, Double(Float(0.707106781)), 1])
        try verify(shifted, segments: approximate(shifted, transform: .identity), transform: .identity)
        let huge = Double(sign: .plus, exponent: 54, significand: 1)
        let unrepresentable = StrokeConic(points: [.init(x: huge + 8, y: huge), .init(x: huge + 8, y: huge + 8),
                                                  .init(x: huge, y: huge + 8)], weights: shifted.weights)
        var budget = try GeometryBudget(maximumDepth: 8)
        #expect(throws: PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")) {
            try StrokeConicApproximation.cubics(unrepresentable, tolerance: 0.0001, transform: .identity, budget: &budget)
        }
    }

    /// 参数错误、精度溢出、工作/字节/深度耗尽都失败，不能返回粗略的最后一段。
    @Test func invalidInputsAndResourceLimitsFail() throws {
        let valid = quarter(radius: 100)
        let invalid = [StrokeConic(points: [], weights: []), StrokeConic(points: valid.points, weights: [1, 0, 1]),
            StrokeConic(points: valid.points, weights: [1, -.infinity, 1]),
            StrokeConic(points: [.zero, .init(x: .nan, y: 0), .zero], weights: [1, 1, 1])]
        for conic in invalid {
            var budget = try GeometryBudget()
            #expect(throws: PAGError.invalidArgument("strokeConic")) {
                try StrokeConicApproximation.cubics(conic, tolerance: 0.1, transform: .identity, budget: &budget)
            }
        }
        for tolerance in [0.0, -1, .infinity, .nan] {
            var budget = try GeometryBudget()
            #expect(throws: PAGError.invalidArgument("geometryTolerance")) {
                try StrokeConicApproximation.cubics(valid, tolerance: tolerance, transform: .identity, budget: &budget)
            }
        }
        for (limit, error) in [
            (try GeometryBudget(maximumBytes: 1023), "maximumRenderGeometryBytes"),
            (try GeometryBudget(maximumWork: 127), "maximumRenderGeometryWork"),
            (try GeometryBudget(maximumDepth: 0), "maximumGeometryCurveDepth")
        ] {
            var budget = limit
            #expect(throws: PAGError.resourceLimitExceeded(error)) {
                try StrokeConicApproximation.cubics(valid, tolerance: 0.01, transform: .identity, budget: &budget)
            }
        }
        var budget = try GeometryBudget()
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try StrokeConicApproximation.cubics(valid, tolerance: 0.01,
                transform: SceneAffine.scale(x: Double.greatestFiniteMagnitude, y: 1), budget: &budget)
        }
    }

    /// 预取消在任何近似输出之前传播CancellationError，不执行后续几何准备。
    @Test func precancelledConversionFails() async throws {
        var budget = try GeometryBudget()
        let conic = quarter(radius: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try StrokeConicApproximation.cubics(conic, tolerance: 0.1, transform: .identity, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 显式的几何语义夹具，不编码PAG字段；权重沿固定PathKit的Float常量。
    private func quarter(radius: Double) -> StrokeConic {
        StrokeConic(points: [.init(x: radius, y: 0), .init(x: radius, y: radius), .init(x: 0, y: radius)],
                    weights: [1, Double(Float(0.707106781)), 1])
    }

    /// 以1/16层坐标单位作为转换份额，用标准预算运行，不参与独立期望计算。
    private func approximate(_ conic: StrokeConic, transform: SceneAffine) throws -> [StrokeCubic] {
        var budget = try GeometryBudget()
        return try StrokeConicApproximation.cubics(conic, tolerance: 1.0 / 16, transform: transform, budget: &budget)
    }

    /// 在每个返回参数区间密集代入原rational公式与三次公式，独立检查变换后误差。
    private func verify(_ conic: StrokeConic, segments: [StrokeCubic], transform: SceneAffine) throws {
        #expect(segments.isEmpty == false)
        for segment in segments {
            #expect(segment.startParameter < segment.endParameter)
            for index in 0...32 {
                let t = Double(index) / 32
                let originalT = segment.startParameter + t * (segment.endParameter - segment.startParameter)
                let actual = cubic(segment, at: t)
                let expected = rational(conic, at: originalT)
                let x = actual.x - expected.x, y = actual.y - expected.y
                let distance = hypot(transform.a * x + transform.c * y, transform.b * x + transform.d * y)
                #expect(distance <= 1.0 / 16)
            }
        }
    }

    /// 原始三个点直接按rational Bernstein定义求值，与生产齐次细分/残差算法独立。
    private func rational(_ curve: StrokeConic, at t: Double) -> ScenePoint {
        let u = 1 - t
        let weights = [u * u * curve.weights[0], 2 * u * t * curve.weights[1], t * t * curve.weights[2]]
        let sum = weights.reduce(0, +)
        var x = 0.0, y = 0.0
        for index in 0..<3 {
            x += weights[index] * curve.points[index].x
            y += weights[index] * curve.points[index].y
        }
        return ScenePoint(x: x / sum, y: y / sum)
    }

    /// 直接求三次Bernstein多项式，只消费实际存储的控制点。
    private func cubic(_ curve: StrokeCubic, at t: Double) -> ScenePoint {
        let u = 1 - t
        let points = [curve.start, curve.first, curve.second, curve.end]
        let weights = [u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t]
        var x = 0.0, y = 0.0
        for index in 0..<4 {
            x += weights[index] * points[index].x
            y += weights[index] * points[index].y
        }
        return ScenePoint(x: x, y: y)
    }
}
