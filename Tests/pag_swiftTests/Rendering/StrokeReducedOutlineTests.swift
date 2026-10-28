import Testing
@testable import pag_swift

/// 可降阶Cubic的真实描边接入，独立验证原始verb状态和几何段状态不能相互替代。
struct StrokeReducedOutlineTests {
    /// 零Cubic没有Line前瞻，先固定默认法线；零Line后接真实线则被前瞻跳过。
    @Test func zeroCubicRetainsItsDefaultNormal() throws {
        let cubic = try strokePath(verbs: [.move, .cubic, .line], points: [.zero, .zero, .zero, .zero, p(10, 0)])
        let line = try strokePath(verbs: [.move, .line, .line], points: [.zero, .zero, p(10, 0)])
        let a = try outline(cubic, cap: .square, join: .bevel), b = try outline(line, cap: .square, join: .bevel)
        #expect(a.points.contains(p(2, 0)))
        #expect(b.points.contains(p(2, 0)) == false)
        #expect(a.points != b.points)
    }

    /// 前一短Line被跳过后，Cubic的P0仍为原点；原始零Cubic因此变成一条真实短线。
    @Test func cubicStartsAtLastAcceptedPoint() throws {
        let small = p(1.0 / 65536, 0)
        let path = try strokePath(verbs: [.move, .line, .cubic, .line], points: [.zero, small, small, small, small, p(10, 0)])
        let result = try outline(path, cap: .square, join: .bevel)
        #expect(result.points.contains(p(0, -2)))
        #expect(result.points.contains(p(2, 0)) == false)
    }

    /// 末Cubic即使降成直线或完全被跳过，Square末帽仍走追加三边分支而非覆盖已有末点。
    @Test func originalCubicControlsEndCapBranch() throws {
        let direct = try strokePath(verbs: [.move, .line], points: [.zero, p(10, 0)])
        let paths = try [
            strokePath(verbs: [.move, .cubic], points: [.zero, p(10, 0), p(10, 0), p(10, 0)]),
            strokePath(verbs: [.move, .line, .cubic], points: [.zero, p(10, 0), p(10, 0), p(10, 0), p(10, 0)])
        ]
        let line = try outline(direct, cap: .square)
        for path in paths {
            let result = try outline(path, cap: .square)
            #expect(result.points.count == line.points.count + 2)
            #expect(result.points.contains(p(10, -2)) && result.points.contains(p(10, 2)))
            #expect(abs(GeometryTestSupport.area(try mesh(result)) - 56) < 1e-8)
        }
    }

    /// 原末Cubic直接回到起点时Close补after角点；存在自动闭合Line时，即使短Line跳过也更新标记。
    @Test func closeDistinguishesCubicFromAutomaticLine() throws {
        let exact = try strokePath(verbs: [.move, .line, .line, .cubic, .close],
            points: [.zero, p(10, 0), p(0, 10), .zero, .zero, .zero])
        let small = p(1.0 / 65536, 0)
        let automatic = try strokePath(verbs: exact.verbs, points: [.zero, p(10, 0), p(0, 10), small, small, small])
        let a = try outline(exact), b = try outline(automatic)
        #expect(a.points.contains(p(-2, -2)))
        #expect(a.points.filter { $0 == p(0, -2) }.count == 2)
        #expect(b.points.count == a.points.count - 1)
    }

    /// 一次共线回折的内部接角必须Round，Butt端帽不会补起点圆盘；面积由矩形加半圆独立计算。
    @Test func reversalUsesRoundOnlyInsideCubic() throws {
        let path = try strokePath(verbs: [.move, .cubic], points: [.zero, p(4, 0), p(4, 0), .zero])
        for join in [SourceLineJoin.miter, .bevel, .round] {
            let mesh = try mesh(outline(path, join: join))
            #expect(abs(GeometryTestSupport.area(mesh) - (12 + 2 * Double.pi)) < 0.02)
            #expect(GeometryTestSupport.coverage(mesh, at: p(-1, 0.17)) == 0)
            #expect(GeometryTestSupport.coverage(mesh, at: p(4.5, 0.17)) == 1)
        }
        let withNext = try strokePath(verbs: [.move, .cubic, .line], points: [.zero, p(4, 0), p(4, 0), .zero, p(0, 10)])
        let bevel = try mesh(outline(withNext, join: .bevel))
        #expect(GeometryTestSupport.coverage(bevel, at: p(-1.2, -1.3)) == 0)
    }

    /// 零Cubic后Close的空范围分支把原末标记改为Line，Square结果与MoveClose一致。
    @Test func emptyCloseOverridesCubicMarker() throws {
        let cubic = try strokePath(verbs: [.move, .cubic, .close], points: [.zero, .zero, .zero, .zero])
        let move = try strokePath(verbs: [.move, .close], points: [.zero])
        let a = try outline(cubic, cap: .square), b = try outline(move, cap: .square)
        #expect(a.verbs == b.verbs && a.points == b.points)
    }

    /// 降阶与真正非线性轮廓在同一候选中完整输出，预算覆盖所有轮廓，不再有nil回退。
    @Test func nonlinearCurveCompletesTheWholeCandidate() throws {
        let path = try strokePath(verbs: [.move, .line, .move, .cubic],
            points: [.zero, p(10, 0), p(30, 0), p(30, 10), p(40, 10), p(40, 0)])
        var budget = try GeometryBudget()
        let admission = try StrokeAdmission.inspect(path, style: style(), budget: &budget)
        let before = budget.work
        let candidate = try StrokeCurveOutline.make(path, admission: admission, style: style(), restoration: .identity,
                                                      tolerance: 0.001, limits: .standard, budget: &budget)
        #expect(candidate.verbs.filter { $0 == .move }.count == 2)
        #expect(candidate.verbs.contains(.cubic))
        #expect(candidate.points.contains { $0.x >= 40 })
        #expect(budget.work > before)
    }

    /// 候选的工作/输出超限继续抛错，不返回残缺路径或用其他后端绕过限额。
    @Test func candidateFailuresDoNotBecomeFallback() throws {
        let path = try strokePath(verbs: [.move, .cubic], points: [.zero, p(4, 0), p(4, 0), .zero])
        var setup = try GeometryBudget()
        let admission = try StrokeAdmission.inspect(path, style: style(), budget: &setup)
        var work = try GeometryBudget(maximumWork: 32)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try StrokeCurveOutline.make(path, admission: admission, style: style(), restoration: .identity,
                                          tolerance: 0.001, limits: .standard, budget: &work)
        }
        var budget = try GeometryBudget()
        #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeOutputElements")) {
            try StrokeCurveOutline.make(path, admission: admission, style: style(), restoration: .identity,
                tolerance: 0.001, limits: StrokeBackendLimits(maximumOutputElements: 2), budget: &budget)
        }
    }

    /// 纯Line闭合接角不能因后面还有其他轮廓而误用Cubic的currIsLine=false。
    @Test func closedLineSeamIgnoresFollowingContourPosition() throws {
        let base = try strokePath(verbs: [.move, .line, .line, .close], points: [.zero, p(10, 0), p(0, 10)])
        let decorated = try strokePath(verbs: base.verbs + [.move, .move], points: base.points + [p(30, 0), p(40, 0)])
        let a = try outline(base), b = try outline(decorated)
        #expect(a.verbs == b.verbs && a.points == b.points)
    }

    /// 宽度四、无dash，用于手算中心线两侧的解析区域。
    private func style(cap: SourceLineCap = .butt, join: SourceLineJoin = .miter) -> StrokeStyle {
        StrokeStyle(width: 4, cap: cap, join: join, miterLimit: 4, dashes: nil)
    }

    /// 通过生产入口核实新分流确实被消费，保留默认预算与最终矩阵规则。
    private func outline(_ path: StrokePath, cap: SourceLineCap = .butt, join: SourceLineJoin = .miter) throws -> SourcePath {
        var budget = try GeometryBudget()
        return try StrokeOutline.make(path, style: style(cap: cap, join: join), tolerance: 0.0005, budget: &budget)
    }

    /// 完整轮廓经既有nonzero网格消费，面积和覆盖期望来自解析几何。
    private func mesh(_ path: SourcePath) throws -> RenderMesh {
        var budget = try GeometryBudget()
        return try GeometryTestSupport.mesh(PathFlattening.sourcePath(path, tolerance: 0.001, budget: &budget))
    }

    /// 手算点的简写，不复用生产求值或矩阵方法。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }
    /// 用独立准备预算发布规范化描边输入，不给生产入口添加旧SourcePath兼容桥。
    private func strokePath(verbs: [StrokePathVerb], points: [ScenePoint]) throws -> StrokePath {
        var budget = try GeometryBudget()
        return try StrokePath(verbs: verbs, points: points, budget: &budget)
    }

}
