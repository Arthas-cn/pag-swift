import Testing
@testable import pag_swift

/// 从真实中心线或临时曲线进入完整dash状态机；验证测量、截取和最终输入接纳共同的行为。
struct StrokeDashingCurveTests {
    /// 单位圆源Conic测长约5.656854，5.8长on覆盖完整圆；完整四段保留原控制点，结果没有Close。
    @Test func unitCircleKeepsAllFourConicsWithoutGap() throws {
        let style = try style([5.8, 0.2])
        let rectangle = try RoundedRectangleContour.make(size: p(2, 2), position: .zero,
            roundness: 1, reversed: false, matrix: .identity)
        let geometry = try ShapeGeometry(contours: [.rectangle(rectangle)],
            stroke: ShapeStroke(style: style, matrix: .identity))
        var budget = try GeometryBudget()
        let centerline = try StrokeCenterline.make(geometry, budget: &budget)
        let result = try StrokeDashing.make(centerline, style: style, budget: &budget)
        #expect(result.verbs == [.move] + Array(repeating: .conic(weight: Float(bitPattern: 0x3F3504F3)), count: 4))
        #expect(result.points == [p(1, 0), p(1, 1), p(0, 1), p(-1, 1), p(-1, 0),
                                  p(-1, -1), p(0, -1), p(1, -1), p(1, 0)])
    }

    /// 长Line吞掉后续半单位短线；dash尾段测距用原曲线，实际Move和部分截取却用compact起点。
    @Test(arguments: [false, true]) func compactCurveStartFlowsIntoPartialDash(conic: Bool) throws {
        let source = try path(verbs: [.move, .line, .line, conic ? .conic(weight: 0.5) : .quad],
            points: [p(-8_388_608, 0), p(8_388_608, 0), p(8_388_608, 0.5),
                     p(8_388_608, 2.5), p(8_388_608, 4.5)])
        var budget = try GeometryBudget()
        // 正phase恰到首on右端，先跳过16777218距离；仅提取最后两单位测量距离。
        let result = try StrokeDashing.make(source, style: style([2, 16_777_218], phase: 2), budget: &budget)
        if conic {
            #expect(result.verbs == [.move, .conic(weight: Float(bitPattern: 0x3F5DB3D8))])
            #expect(result.points == [bits(0x4B000000, 0x40155555), bits(0x4B000000, 0x40755555), p(8_388_608, 4.5)])
        } else {
            #expect(result.verbs == [.move, .quad])
            #expect(result.points == [p(8_388_608, 2.375), p(8_388_608, 3.5), p(8_388_608, 4.5)])
        }
    }

    /// 零周期属于源无效effect；接纳合法有限数据后直接保留原Conic，不调用会溢出的测量公式。
    @Test func invalidEffectPreservesUnmeasuredConic() throws {
        let source = try path(verbs: [.move, .conic(weight: .greatestFiniteMagnitude)],
                              points: [p(1, 0), p(1, 1), p(0, 1)])
        var budget = try GeometryBudget()
        let result = try StrokeDashing.make(source, style: style([0, 0]), budget: &budget)
        #expect(result.verbs == source.verbs && result.points == source.points)
    }

    /// 一个合法三点输入被切成多个on之后，必须重新执行较小的输入点配额，不能只检查输出配额。
    @Test(arguments: [false, true]) func dashedCurveIsReadmittedAsNewInput(conic: Bool) throws {
        let source = try path(verbs: [.move, conic ? .conic(weight: Float(bitPattern: 0x3F3504F3)) : .quad],
                              points: [p(1, 0), p(1, 1), p(0, 1)])
        let limits = try StrokeBackendLimits(maximumInputPoints: 3)
        var budget = try GeometryBudget()
        #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeInputPoints")) {
            try StrokeDashing.make(source, style: style([0.5, 0.5]), limits: limits, budget: &budget)
        }
        #expect(budget.work > 3)
    }

    /// 前一轮廓已经成功提取，后一Conic的必要mid求值溢出仍使整份结果失败，不能发布已有前缀。
    @Test func laterConicPrecisionFailureDiscardsEarlierDash() throws {
        let source = try path(verbs: [.move, .line, .move, .conic(weight: .greatestFiniteMagnitude)],
                              points: [.zero, p(1, 0), p(1, 0), p(1, 1), p(0, 1)])
        var budget = try GeometryBudget()
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try StrokeDashing.make(source, style: style([1, 1]), budget: &budget)
        }
        #expect(budget.work > 5)
    }

    /// 从真实源参数规范化入口创建样式；nil保留无效effect的实线语义。
    private func style(_ intervals: [Double], phase: Double = 0) throws -> StrokeStyle {
        try StrokeStyle(width: 4, cap: .round, join: .round, miterLimit: 4,
                        dashes: StrokeDashPattern.make(intervals: intervals, phase: phase))
    }

    /// 测试夹具在独立预算中完成不可变模型验证，不把构造成本混进失败注入预算。
    private func path(verbs: [StrokePathVerb], points: [ScenePoint]) throws -> StrokePath {
        var setup = try GeometryBudget()
        return try StrokePath(verbs: verbs, points: points, budget: &setup)
    }

    /// 使用独立Float探针固定的位模式，期望值不通过生产截取器求得。
    private func bits(_ x: UInt32, _ y: UInt32) -> ScenePoint {
        p(Double(Float(bitPattern: x)), Double(Float(bitPattern: y)))
    }

    /// 简写手算几何坐标，原样保留测试声明的Double值。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }
}
