import Testing
@testable import pag_swift

/// Quad/Conic进入真实测量与提取链后的独立源数值；不借生产曲线helper计算期望。
struct StrokeDashExtractionTests {
    /// full[0,1]先复制Double存储，不能先构造Float helper；曲线起点不覆盖调用方已有Move。
    @Test(arguments: [false, true]) func wholeCurveCopiesStoredDoubleBeforeFloatConversion(conic: Bool) throws {
        let control = p(Double(1).nextUp, Double(2).nextDown)
        let end = p(Double(3).nextDown, Double(4).nextUp)
        let curve: StrokeDashCurve = conic ? .conic(start: .zero, control: control, end: end, weight: 0.5)
                                          : .quad(start: .zero, control: control, end: end)
        var budget = try GeometryBudget()
        let output = try StrokeDashOutput(budget: &budget, limits: .standard)
        try output.append(.move, points: [p(9, 7)])
        try curve.append(from: 0, to: 1, to: output)
        let result = try output.finish()
        #expect(result.verbs == [.move, conic ? .conic(weight: 0.5) : .quad])
        #expect(result.points == [p(9, 7), control, end])
        #expect(Double(Float(control.x)) != control.x && Double(Float(end.x)) != end.x)
    }

    /// 普通Quad在1/4...3/4按源两次Float chop截取，保留Q控制点且不追加第二个Move。
    @Test func partialQuadUsesSourceChopOrder() throws {
        let curve = StrokeDashCurve.quad(start: .zero, control: p(0, 4), end: p(4, 0))
        var budget = try GeometryBudget()
        let output = try StrokeDashOutput(budget: &budget, limits: .standard)
        try output.append(.move, points: [p(0.25, 1.5)])
        try curve.append(from: 0.25, to: 0.75, to: output)
        let result = try output.finish()
        #expect(result.verbs == [.move, .quad])
        #expect(result.points == [p(0.25, 1.5), p(0.75, 2.5), p(2.25, 1.5)])
    }

    /// 四分圆内部区间按双参数重建，控制点与权重来自独立Float公式，segment.start不会写回输出。
    @Test func partialConicPreservesWeightAndExistingMove() throws {
        let curve = StrokeDashCurve.conic(start: p(1, 0), control: p(1, 1), end: p(0, 1), weight: Float(bitPattern: 0x3F3504F3))
        var budget = try GeometryBudget()
        let output = try StrokeDashOutput(budget: &budget, limits: .standard)
        try output.append(.move, points: [p(9, 7)])
        try curve.append(from: 0.25, to: 0.75, to: output)
        let result = try output.finish()
        #expect(result.verbs == [.move, .conic(weight: Float(bitPattern: 0x3F6AF123))])
        #expect(result.points == [p(9, 7), bits(0x3F453E88, 0x3F453E88), bits(0x3EBC76EB, 0x3F6E069C)])
    }

    /// Move的Float Horner末点可以不同于完整段保存末点；零范围新Move必须使用前者。
    @Test(arguments: [false, true]) func endpointHornerDoesNotRewriteStoredEndpoint(conic: Bool) throws {
        let end = bits(0x3DCCCCCD, 0)
        let source = try path(verbs: [.move, conic ? .conic(weight: 0.5) : .quad], points: [p(1, 0), .zero, end])
        let measure = try measure(source)
        let length = Float(bitPattern: 0x3F666666)
        #expect(measure.records.count == 1 && measure.length == length)
        let full = try extract(measure, from: 0, to: length)
        #expect(full.points == [p(1, 0), .zero, end])
        let zero = try extract(measure, from: length, to: length)
        #expect(zero.verbs == [.move, .line])
        #expect(zero.points == [bits(0x3DCCCCD0, 0), bits(0x3DCCCCD0, 0)])
        var budget = try GeometryBudget()
        let output = try StrokeDashOutput(budget: &budget, limits: .standard)
        try output.append(.move, points: [p(9, 7)])
        try measure.append(from: length, to: length, startsNewContour: false, to: output)
        #expect(try output.finish().points == [p(9, 7), p(9, 7)])
    }

    /// 相邻距离在四分圆上得到相邻Float参数，重建权重恰为1时真实临时输出必须规范化为Quad。
    @Test func adjacentDistanceConicBecomesQuad() throws {
        let source = try path(verbs: [.move, .conic(weight: Float(bitPattern: 0x3F3504F3))],
                              points: [p(1, 0), p(1, 1), p(0, 1)])
        let measure = try measure(source)
        #expect(measure.length.bitPattern == 0x3FB504F3 && measure.records.count == 1)
        let result = try extract(measure, from: Float(bitPattern: 0x3F3504F3), to: Float(bitPattern: 0x3F3504F4))
        #expect(result.verbs == [.move, .quad])
        #expect(result.points == [bits(0x3F3504F3, 0x3F3504F3), bits(0x3F3504F5, 0x3F3504F3),
                                  bits(0x3F3504F1, 0x3F3504F3)])
    }

    /// 跨曲线恰从前Quad终点开始时lower-bound不跳到下一段，先追加精确零Line再写后段。
    @Test func boundaryBetweenCurvesKeepsZeroLine() throws {
        let source = try path(verbs: [.move, .quad, .conic(weight: 0.5)],
                              points: [.zero, p(1, 0), p(2, 0), p(3, 0), p(4, 0)])
        let measure = try measure(source)
        #expect(measure.records.map(\.distance) == [2, 4])
        let result = try extract(measure, from: 2, to: 4)
        #expect(result.verbs == [.move, .line, .conic(weight: 0.5)])
        #expect(result.points == [p(2, 0), p(2, 0), p(3, 0), p(4, 0)])
    }

    /// 被吞短段不改变后曲线测量起点；提取起点与Close却来自最后保留的原存储端点。
    @Test(arguments: [false, true]) func compactOutputAndCloseKeepStoredGeometry(conic: Bool) throws {
        let kind: StrokePathVerb = conic ? .conic(weight: 0.5) : .quad
        let source = try path(verbs: [.move, .line, .line, kind, .line, .close],
            points: [p(-8_388_608, 0), p(8_388_608, 0), p(8_388_608, 0.5),
                     p(8_388_608, 2.5), p(8_388_608, 4.5), p(8_388_608, 4.75)])
        let measure = try measure(source)
        #expect(measure.records.map(\.distance) == [16_777_216, 16_777_220, 33_554_436])
        try #require(measure.curves.count == 3)
        #expect(measure.curves[1].start == p(8_388_608, 0))
        #expect(measure.curves[1].end == p(8_388_608, 4.5))
        #expect(measure.curves[2].start == p(8_388_608, 4.5) && measure.curves[2].end == p(-8_388_608, 0))
    }

    /// 采样入口验证参数并拒绝Float溢出；部分提取也不能借整段直通绕过必要数值检查。
    @Test func invalidSamplingAndPartialPrecisionFail() throws {
        let ordinary = StrokeDashCurve.quad(start: .zero, control: p(1, 1), end: p(2, 0))
        for parameter: Float in [-1, .nan, .infinity, 2] {
            var budget = try GeometryBudget()
            #expect(throws: PAGError.invalidArgument("strokeCurveParameter")) { try ordinary.point(at: parameter, budget: &budget) }
        }
        let huge = StrokeDashCurve.quad(start: p(1e100, 0), control: p(1e100, 1), end: p(1e100, 2))
        var budget = try GeometryBudget()
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) { try huge.point(at: 0, budget: &budget) }
        let output = try StrokeDashOutput(budget: &budget, limits: .standard)
        try output.append(.move, points: [.zero])
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) { try huge.append(from: 0, to: 0.5, to: output) }
    }

    /// 控制点已存储但尚未提取时取消，Float采样入口必须立即传播取消。
    @Test func cancelledSamplingDoesNotProduceMove() async throws {
        let task = Task {
            var budget = try GeometryBudget()
            let curve = StrokeDashCurve.conic(start: p(1, 0), control: p(1, 1), end: p(0, 1), weight: 0.5)
            withUnsafeCurrentTask { $0?.cancel() }
            return try curve.point(at: 0, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 使用输入接纳与真正测量入口，不由基础helper生成记录或期望。
    private func measure(_ path: StrokePath) throws -> StrokeDashMeasure {
        var budget = try GeometryBudget()
        let style = StrokeStyle(width: 4, cap: .butt, join: .bevel, miterLimit: 4, dashes: nil)
        let admission = try StrokeAdmission.inspect(path, style: style, budget: &budget)
        let contour = try #require(admission.subpaths.first)
        return try #require(try StrokeDashMeasure.make(path, contour: contour, budget: &budget))
    }

    /// 在真实临时输出器中提取单个新轮廓并完整发布。
    private func extract(_ measure: StrokeDashMeasure, from start: Float, to end: Float) throws -> StrokePath {
        var budget = try GeometryBudget()
        let output = try StrokeDashOutput(budget: &budget, limits: .standard)
        try measure.append(from: start, to: end, startsNewContour: true, to: output)
        return try output.finish()
    }

    /// 模型夹具构造单独计费，失败注入不依赖准备成本。
    private func path(verbs: [StrokePathVerb], points: [ScenePoint]) throws -> StrokePath {
        var setup = try GeometryBudget()
        return try StrokePath(verbs: verbs, points: points, budget: &setup)
    }

    /// 用独立探针固定的Float位模式提升为测试期望，不调用生产曲线公式。
    private func bits(_ x: UInt32, _ y: UInt32) -> ScenePoint {
        p(Double(Float(bitPattern: x)), Double(Float(bitPattern: y)))
    }

    /// 简写手算Double点，避免期望值经过额外量化。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }
}
