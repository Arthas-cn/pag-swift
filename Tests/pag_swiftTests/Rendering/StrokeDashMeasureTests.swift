import Testing
@testable import pag_swift

/// 固定源码Float测量、compact点及原曲线提取的独立手算场景，不使用CG dash作为期望。
struct StrokeDashMeasureTests {
    /// 命中段端点选择前一段，跨段提取因此保留重复Line；范围末端正常钳制。
    @Test func exactDistanceBoundaryKeepsPreviousEndpoint() throws {
        let measure = try #require(try measure(path([p(0, 0), p(10, 0), p(10, 10)])))
        #expect(measure.length == 20)
        let result = try extract(measure, from: 10, to: 100)
        #expect(result.verbs == [.move, .line, .line])
        #expect(result.points == [p(10, 0), p(10, 0), p(10, 10)])
        let zero = try extract(measure, from: -1, to: 0)
        #expect(zero.verbs == [.move, .line] && zero.points == [.zero, .zero])
    }

    /// Float累计吞掉短段时，后段按原端点测长、按保留点出图；Close从最后保留点回首点。
    @Test func swallowedDistancesKeepSourceCompactGeometry() throws {
        let n = Double(16_777_216)
        let source = try path([.zero, p(n, 0), p(n, 1), p(n - 4, 1), p(n - 4, 1.5)], closed: true)
        let measure = try #require(try measure(source))
        #expect(measure.records.map(\.distance) == [16_777_216, 16_777_220, 33_554_432])
        let middle = try extract(measure, from: 16_777_218, to: 16_777_220)
        #expect(middle.verbs == [.move, .line])
        #expect(middle.points == [p(n - 2, 0.5), p(n - 4, 1)])
        let full = try extract(measure, from: 0, to: measure.length)
        #expect(full.verbs == [.move, .line, .line, .line])
        #expect(full.points == [.zero, p(n, 0), p(n - 4, 1), .zero])
    }

    /// 没有NearlyZero测量阈值；小于1/4096仍保留，只有Float平方真正下溢时才归零。
    @Test func tinyLengthUsesFloatSquaredDistance() throws {
        for exponent in [-20, -74] {
            let length = Float(sign: .plus, exponent: exponent, significand: 1)
            let measure = try #require(try measure(path([.zero, p(Double(length), 0)])))
            #expect(measure.length == length)
        }
        let underflow = Float(sign: .plus, exponent: -75, significand: 1)
        #expect(try measure(path([.zero, p(Double(underflow), 0)])) == nil)
    }

    /// Float平方溢出但长度仍有限时沿源Double回退；放大测试限额不改变生产默认坐标政策。
    @Test func squaredOverflowUsesSourceDoubleFallback() throws {
        let length = Float(sign: .plus, exponent: 80, significand: 1)
        let measure = try #require(try measure(path([.zero, p(Double(length), 0)]), maximumMagnitude: Double(length) * 2))
        #expect(measure.length == length)
        #expect(measure.records.count == 1 && measure.records[0].parameter == 1)
    }

    /// 参数非匀速的共线cubic仍细分测量；提取原曲线尾部而非测量叶弦。
    @Test func collinearCubicRetainsParameterization() throws {
        let source = try path(verbs: [.move, .cubic], points: [.zero, .zero, .zero, p(8, 0)])
        let measure = try #require(try measure(source))
        #expect(measure.length == 8 && measure.records.count > 1 && measure.curves.count == 1)
        let full = try extract(measure, from: 0, to: 8)
        #expect(full.verbs == source.verbs && full.points == source.points)
        let tail = try extract(measure, from: 1, to: 8)
        #expect(tail.verbs == [.move, .cubic])
        #expect(tail.points == [p(1, 0), p(2, 0), p(4, 0), p(8, 0)])
    }

    /// 真正弯曲的cubic在测量半参数处截取后，控制点与手算de Casteljau尾段相同。
    @Test func curvedCubicExtractionKeepsControlPoints() throws {
        let source = try path(verbs: [.move, .cubic], points: [.zero, p(0, 12), p(12, 12), p(12, 0)])
        let measure = try #require(try measure(source))
        let half = try #require(measure.records.first { $0.parameter == 0.5 })
        let tail = try extract(measure, from: half.distance, to: measure.length)
        #expect(tail.verbs == [.move, .cubic])
        #expect(tail.points == [p(6, 9), p(9, 9), p(12, 6), p(12, 0)])
    }

    /// 无测量段的轮廓消失，曲线超深度和非法提取范围都明确失败。
    @Test func emptyContoursAndLimitsRemainExplicit() throws {
        for verbs: [StrokePathVerb] in [[.move], [.move, .close], [.move, .cubic, .close]] {
            let source = try path(verbs: verbs, points: Array(repeating: .zero, count: verbs.reduce(0) { $0 + $1.pointCount }))
            #expect(try measure(source) == nil)
        }
        let source = try path(verbs: [.move, .cubic], points: [.zero, p(0, 12), p(12, 12), p(12, 0)])
        var budget = try GeometryBudget(maximumDepth: 0)
        let contour = StrokeSubpath(verbs: 0..<2, points: 0..<4, lengthUpperBound: 36, hasSegments: true, isClosed: false)
        #expect(throws: PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")) {
            try StrokeDashMeasure.make(source, contour: contour, budget: &budget)
        }
        let line = try #require(try measure(path([.zero, p(10, 0)])))
        #expect(throws: PAGError.invalidArgument("strokeDashRange")) { try extract(line, from: 11, to: 20) }
        #expect(throws: PAGError.invalidArgument("strokeDashRange")) { try extract(line, from: .nan, to: 10) }
        #expect(throws: PAGError.invalidArgument("strokeDashRange")) { try extract(line, from: 0, to: .nan) }
    }

    /// 接纳单条纯语义路径；自定义幅度只为覆盖Float边界样例，不进入系统描边。
    private func measure(_ path: StrokePath, maximumMagnitude: Double = 33_554_432) throws -> StrokeDashMeasure? {
        var budget = try GeometryBudget()
        let style = StrokeStyle(width: 4, cap: .butt, join: .bevel, miterLimit: 4, dashes: nil)
        let admission = try StrokeAdmission.inspect(path, style: style, limits: StrokeBackendLimits(maximumMagnitude: maximumMagnitude), budget: &budget)
        let contour = try #require(admission.subpaths.first)
        return try StrokeDashMeasure.make(path, contour: contour, budget: &budget)
    }

    /// 通过真实输出计费器提取路径，测试范围以Float表达源码距离。
    private func extract(_ measure: StrokeDashMeasure, from start: Float, to end: Float) throws -> StrokePath {
        var outputBudget = try GeometryBudget()
        let output = try StrokeDashOutput(budget: &outputBudget, limits: StrokeBackendLimits(maximumMagnitude: 33_554_432))
        try measure.append(from: start, to: end, startsNewContour: true, to: output)
        return try output.finish()
    }

    /// 建立开放或闭合语义折线，不写PAG字节夹具。
    private func path(_ points: [ScenePoint], closed: Bool = false) throws -> StrokePath {
        try path(verbs: [.move] + Array(repeating: .line, count: points.count - 1) + (closed ? [.close] : []), points: points)
    }

    /// 在独立准备预算中发布临时测试路径；测试执行预算不包含夹具构造成本。
    private func path(verbs: [StrokePathVerb], points: [ScenePoint]) throws -> StrokePath {
        var setup = try GeometryBudget()
        return try StrokePath(verbs: verbs, points: points, budget: &setup)
    }

    /// 保留手算期望使用的Double坐标。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }
}
