import Testing
@testable import pag_swift

/// Trim的源Float采样/截取金值，期望由独立逐步Float公式和手算给出，不调用生产helper生成。
struct TrimCurveExtractionTests {
    /// 原曲线Horner与切分de Casteljau相差一ULP时，独立Move和切片末点分别保留。
    @Test func cubicPositionAndChopKeepDifferentRounding() throws {
        let curve = StrokeDashCurve.cubic(start: p(0), first: p(1), second: p(0), end: p(1))
        var budget = try GeometryBudget()
        let point = try TrimCurveExtraction.point(on: curve, at: 0.1, budget: &budget)
        #expect(Float(point.x).bitPattern == 0x3E79DB23)
        let result = try extract(curve, from: 0, to: 0.1)
        #expect(Float(try #require(result.points.last).x).bitPattern == 0x3E79DB24)
        let other = StrokeDashCurve.cubic(start: p(0), first: p(0), second: p(1), end: p(0))
        #expect(Float(try TrimCurveExtraction.point(on: other, at: Float(1) / 3, budget: &budget).x).bitPattern == 0x3E638E3A)
        let cut = try extract(other, from: 0, to: Float(1) / 3)
        #expect(Float(try #require(cut.points.last).x).bitPattern == 0x3E638E39)
    }

    /// 两次chop的归一参数必须用Float计算，切片终点不以原Horner位置“修齐”。
    @Test func interiorCubicUsesSourceNormalizedParameter() throws {
        let curve = StrokeDashCurve.cubic(start: p(0, 0), first: p(0, 4), second: p(4, 4), end: p(4, 0))
        let half = try extract(curve, from: 0.25, to: 0.75)
        #expect(half.points == [p(0.625, 2.25), p(1.375, 3.25), p(2.625, 3.25), p(3.375, 2.25)])
        let third = try extract(curve, from: Float(1) / 3, to: Float(2) / 3)
        #expect(third.verbs == [.move, .cubic])
        #expect(third.points == [bits(0x3F84BDA2, 0x402AAAAB), bits(0x3FD097B6, 0x40471C72),
                                 bits(0x4017B427, 0x40471C71), bits(0x403DA130, 0x402AAAA9)])
    }

    /// t1位置也执行Float公式，但非零片段的Line末点/整段Cubic控制点取原存储；零片段取当前Move。
    @Test func endpointSamplingDoesNotReplaceStoredEnd() throws {
        let line = StrokeDashCurve.line(start: p(16_777_216), end: p(-1))
        var budget = try GeometryBudget()
        #expect(try TrimCurveExtraction.point(on: line, at: 1, budget: &budget) == p(0))
        #expect(try extract(line, from: 0.5, to: 1).points == [p(8_388_608), p(-1)])
        #expect(try extract(line, from: 1, to: 1).points == [p(0), p(0)])
        let cubic = StrokeDashCurve.cubic(start: p(16_777_216), first: p(0), second: p(0), end: p(1))
        #expect(try TrimCurveExtraction.point(on: cubic, at: 1, budget: &budget) == p(0))
        #expect(try extract(cubic, from: 0, to: 1).points == [p(16_777_216), p(0), p(0), p(1)])
        let source = try TrimCubicCurve(start: SIMD2(16_777_216, 0), first: .zero, second: .zero, end: SIMD2(1, 0))
        let pair = try source.split(at: 1, budget: &budget)
        #expect(pair.first.end == SIMD2(1, 0) && pair.second.start == pair.second.end)
        #expect(pair.second.first == SIMD2(1, 0) && pair.second.second == SIMD2(1, 0))
    }

    /// Quad与Conic共用已取证Float内核，新writer仍保留曲线类型和权重，不转成折线。
    @Test func quadAndConicRemainNativeCurves() throws {
        let quad = StrokeDashCurve.quad(start: .zero, control: p(0, 4), end: p(4, 0))
        #expect(try extract(quad, from: 0.25, to: 0.75).points == [p(0.25, 1.5), p(0.75, 2.5), p(2.25, 1.5)])
        let conic = StrokeDashCurve.conic(start: p(1, 0), control: p(1, 1), end: p(0, 1), weight: Float(bitPattern: 0x3F3504F3))
        let result = try extract(conic, from: 0.25, to: 0.75)
        #expect(result.verbs == [.move, .conic(weight: Float(bitPattern: 0x3F6AF123))])
        #expect(result.points == [bits(0x3F6E069B, 0x3EBC76E9), bits(0x3F453E88, 0x3F453E88), bits(0x3EBC76EB, 0x3F6E069C)])
    }

    /// 曲线部分提取的精度失败、工作/内存耗尽与预取消均抛出，不能伪装成成功空路径。
    @Test func precisionBudgetAndCancellationFailuresPropagate() async throws {
        let curve = StrokeDashCurve.cubic(start: p(0), first: p(1e100), second: p(1), end: p(2))
        var writer = TrimPathWriter(budget: try GeometryBudget())
        try writer.append(.move, points: [.zero])
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try TrimCurveExtraction.append(curve, from: 0, to: 0.5, to: &writer)
        }
        let ordinary = StrokeDashCurve.cubic(start: .zero, first: p(0, 4), second: p(4, 4), end: p(4, 0))
        var budget = try GeometryBudget(maximumBytes: 63)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try TrimCurveExtraction.point(on: ordinary, at: 0.5, budget: &budget)
        }
        await #expect(throws: CancellationError.self) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                let prepared = try GeometryBudget()
                group.cancelAll()
                group.addTask {
                    var budget = prepared
                    _ = try TrimCurveExtraction.point(on: ordinary, at: 0.5, budget: &budget)
                }
                for try await _ in group {}
            }
        }
    }

    /// 真实提取步骤先独立采样Move，再写曲线段；不通过测量表反求用于金值验证的参数。
    private func extract(_ curve: StrokeDashCurve, from start: Float, to end: Float) throws -> StrokePath {
        var writer = TrimPathWriter(budget: try GeometryBudget())
        let point = try TrimCurveExtraction.point(on: curve, at: start, budget: &writer.budget)
        try writer.append(.move, points: [point])
        try TrimCurveExtraction.append(curve, from: start, to: end, to: &writer)
        return try writer.finish()
    }

    /// 手算坐标直接进入纯值路径，与生产曲线生成无关。
    private func p(_ x: Double, _ y: Double = 0) -> ScenePoint { ScenePoint(x: x, y: y) }

    /// 将独立逐步Float公式得到的位模式提升为Double存储，避免十进制预期再次舍入。
    private func bits(_ x: UInt32, _ y: UInt32) -> ScenePoint {
        ScenePoint(x: Double(Float(bitPattern: x)), y: Double(Float(bitPattern: y)))
    }
}
