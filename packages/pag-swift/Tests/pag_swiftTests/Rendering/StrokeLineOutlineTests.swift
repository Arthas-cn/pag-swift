import Testing
@testable import pag_swift

/// 纯Line消费者的独立状态机用例，检查短边、原始前瞻、Close和真实端帽位置。
struct StrokeLineOutlineTests {
    /// τ以内Butt为空，其他cap只保留没有后继切向的首短线；τ上界是包含关系。
    @Test func shortLineThresholdAndCaps() throws {
        let threshold = 1.0 / 16384
        for length in [threshold * 0.25, threshold, Double(Float(threshold).nextUp)] {
            let source = try path([.zero, p(length, 0)])
            let butt = try outline(source)
            #expect(butt.verbs.isEmpty == (length <= threshold))
            let square = try outline(source, cap: .square)
            #expect(square.points.map(\.x).min() == -2)
            #expect(square.points.map(\.x).max() == Double(Float(length) + 2))
        }
    }

    /// 连续短边从最后接受点累计；逐原始边各自删除会错误地丢失最后跨阈值的线段。
    @Test func skippedLinesDoNotAdvanceAcceptedPoint() throws {
        let threshold = 1.0 / 16384
        let source = try path([.zero, p(threshold * 0.5, 0), p(threshold, 0), p(threshold * 1.5, 0)])
        let direct = try path([.zero, p(threshold * 1.5, 0)])
        for cap in [SourceLineCap.butt, .round, .square] {
            let actual = try outline(source, cap: cap), expected = try outline(direct, cap: cap)
            #expect(actual.verbs == expected.verbs && actual.points == expected.points)
        }
    }

    /// Close的原始非零补线参与前瞻：首短线跳过，最后以原点零段收尾，不能在ε处加帽。
    @Test func closingLineParticipatesInLookahead() throws {
        let source = try path([.zero, p(1.0 / 65536, 0)], closed: true)
        let zero = try path([.zero, .zero])
        for cap in [SourceLineCap.butt, .round, .square] {
            let actual = try outline(source, cap: cap), expected = try outline(zero, cap: cap)
            #expect(actual.verbs == expected.verbs && actual.points == expected.points)
        }
    }

    /// 首零Line有真实后继时不固定默认法线，末短Line跳过后端帽仍在上次接受点。
    @Test func repeatedAndLateShortLinesPreserveEndpoints() throws {
        let source = try path([.zero, .zero, p(10, 0), p(10 + 1.0 / 65536, 0)])
        let direct = try path([.zero, p(10, 0)])
        for cap in [SourceLineCap.butt, .round, .square] {
            let actual = try outline(source, cap: cap), expected = try outline(direct, cap: cap)
            #expect(actual.verbs == expected.verbs && actual.points == expected.points)
        }
    }

    /// 单独尾Move被Iter吞掉；两个尾Move会触发旧轮廓的非Line square末帽入口。
    @Test func trailingMoveUsesCorrectSquareCapBranch() throws {
        let base = try path([.zero, p(10, 0)])
        let one = try strokePath(verbs: base.verbs + [.move], points: base.points + [p(20, 30)])
        let two = try strokePath(verbs: base.verbs + [.move, .move], points: base.points + [p(20, 30), p(40, 50)])
        let a = try outline(base, cap: .square), b = try outline(one, cap: .square), c = try outline(two, cap: .square)
        #expect(a.verbs == b.verbs && a.points == b.points)
        #expect(c.points.count == a.points.count + 2)
        #expect(c.points.contains(p(10, 2)) && c.points.contains(p(10, -2)))
        #expect(abs(GeometryTestSupport.area(try mesh(c)) - 56) < 1e-8)
    }

    /// 轻微转向的Round/Miter整个join为空，输出仅有四个offset线端点和两个Butt连接。
    @Test func nearlyStraightJoinsDoNotAddPivotOrArc() throws {
        let source = try path([.zero, p(10, 0), p(20, 0.1)])
        for join in [SourceLineJoin.miter, .round] {
            let result = try outline(source, join: join)
            #expect(result.verbs == [.move] + Array(repeating: .line, count: 6) + [.close])
            #expect(result.points.contains(p(10, 0)) == false)
        }
        let bevel = try outline(source, join: .bevel)
        #expect(bevel.points.contains(p(10, 0)))
    }

    /// 非零斜向原始短边经前瞻后只接受零段，Close应检查边界并留给开放端帽。
    @Test func closeChecksActualFloatBoundaryExtent() throws {
        let size = Double(Float.leastNonzeroMagnitude)
        let source = try path([.zero, p(size, size)], closed: true)
        let reference = try path([.zero, .zero])
        let actual = try outline(source, cap: .round), expected = try outline(reference, cap: .round)
        #expect(actual.verbs == expected.verbs && actual.points == expected.points)
    }

    /// 大量零Line的前瞻与描边保持线性工作量，不能为每个零段重扫后续整条路径。
    @Test func repeatedPointLookaheadFitsLinearWorkBudget() throws {
        let source = try path(Array(repeating: .zero, count: 2_000) + [p(10, 0)])
        var budget = try GeometryBudget(maximumWork: 30_000)
        let result = try StrokeOutline.make(source, style: style(cap: .square), tolerance: 0.001, budget: &budget)
        #expect(result.points.map(\.x).max() == 12)
    }

    /// 通过矩阵恢复的Line轮廓与原轮廓逐点一致，临时边界同样遵守最终输出element政策。
    @Test func finalRestorationAndTemporaryBudgets() throws {
        let source = try path([.zero, p(10, 0), p(10, 10)])
        let matrix = try SceneAffine(a: -3, b: 0, c: 0, d: 2, tx: 9, ty: 17)
        let base = try outline(source), transformed = try outline(source, matrix: matrix)
        #expect(transformed.points == base.points.map { p(9 - 3 * $0.x, 17 + 2 * $0.y) })
        var budget = try GeometryBudget()
        #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeOutputElements")) {
            try StrokeOutline.make(source, style: style(), tolerance: 0.001,
                limits: StrokeBackendLimits(maximumOutputElements: 2), budget: &budget)
        }
    }

    /// 从独立几何坐标生成规范化语义路径，未构造任何PAG字节。
    private func path(_ points: [ScenePoint], closed: Bool = false) throws -> StrokePath {
        try strokePath(verbs: [.move] + Array(repeating: .line, count: points.count - 1) + (closed ? [.close] : []), points: points)
    }

    /// 半宽二的实线样式，所有输入已明确cap/join，不依赖平台默认值。
    private func style(cap: SourceLineCap = .butt, join: SourceLineJoin = .miter) -> StrokeStyle {
        StrokeStyle(width: 4, cap: cap, join: join, miterLimit: 4, dashes: nil)
    }

    /// 通过生产分流入口生成轮廓，避免只测没有实际消费者的辅助函数。
    private func outline(_ path: StrokePath, cap: SourceLineCap = .butt, join: SourceLineJoin = .miter,
                         matrix: SceneAffine = .identity) throws -> SourcePath {
        var budget = try GeometryBudget()
        return try StrokeOutline.make(path, style: style(cap: cap, join: join), restoration: matrix, tolerance: 0.0005, budget: &budget)
    }

    /// 以真实折线/nonzero链检查面积，不调用平台stroke作为期望值。
    private func mesh(_ path: SourcePath) throws -> RenderMesh {
        var budget = try GeometryBudget()
        return try GeometryTestSupport.mesh(PathFlattening.sourcePath(path, tolerance: 0.001, budget: &budget))
    }

    /// 手算点的简写，保持期望与生产Float辅助方法独立。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }
    /// 用独立准备预算发布规范化描边输入，不给生产入口添加旧SourcePath兼容桥。
    private func strokePath(verbs: [StrokePathVerb], points: [ScenePoint]) throws -> StrokePath {
        var budget = try GeometryBudget()
        return try StrokePath(verbs: verbs, points: points, budget: &budget)
    }

}
