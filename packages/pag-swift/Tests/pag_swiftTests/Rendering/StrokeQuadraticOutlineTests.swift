import Testing
@testable import pag_swift

/// Quad/Conic完整轮廓接入，独立核对偏移控制点、降阶状态、闭合缝和候选原子失败。
struct StrokeQuadraticOutlineTests {
    /// 轴向首末切向的Quad两侧都是手算整数Q，完整反向输出保留两侧控制点和Butt连接。
    @Test func quadraticArchReachesFinalSourcePath() throws {
        let source = try path([.move, .quad], [.zero, p(0, 4), p(4, 4)])
        let result = try outline(source, width: 2)
        try expect(result, start: p(1, 0), steps: [
            .line(p(-1, 0)), .quad(p(-1, 5), p(4, 5)), .line(p(4, 3)), .quad(p(1, 3), p(1, 0))])
        let mesh = try mesh(result)
        #expect(GeometryTestSupport.coverage(mesh, at: p(0.1, 1)) == 1)
        #expect(GeometryTestSupport.coverage(mesh, at: p(3, 1)) == 0)
    }

    /// 单位Conic半宽1的外Q为(2,0)-(2,2)-(0,2)，内侧坍缩零Line仍留在完整拓扑中。
    @Test func conicQuarterRetainsCollapsedInnerBoundary() throws {
        let source = try path([.move, .conic(weight: Float(bitPattern: 0x3F3504F3))], [p(1, 0), p(1, 1), p(0, 1)])
        let result = try outline(source, width: 2)
        try expect(result, start: p(2, 0), steps: [
            .line(.zero), .line(.zero), .line(p(0, 2)), .quad(p(2, 2), p(2, 0))])
        // 这里是源偏移Q的解析面积10/3，不把有限分段偏移冒充数学精确的圆环。
        #expect(abs(GeometryTestSupport.area(try mesh(result)) - 10.0 / 3) < 0.005)
    }

    /// 真曲线前的极短Line不推进接受点，Quad/Conic必须从原Move构造而非从被丢终点开始。
    @Test func nonlinearCurvesStartAtLastAcceptedPoint() throws {
        for verb in curves {
            let source = try path([.move, verb], [.zero, p(0, 4), p(4, 4)])
            let decorated = try path([.move, .line, verb], [.zero, p(1.0 / 65536, 0), p(0, 4), p(4, 4)])
            let expected = try outline(source), actual = try outline(decorated)
            #expect(actual.verbs == expected.verbs && actual.points == expected.points)
        }
    }

    /// 零曲线按无前瞻lineTo保留默认法线；零Line会被后继切向跳过，两者不能合并处理。
    @Test func zeroCurvesKeepDefaultNormalWithoutLineLookahead() throws {
        let direct = try path([.move, .line, .line], [.zero, .zero, p(10, 0)])
        let line = try outline(direct, cap: .square, join: .bevel)
        for verb in curves {
            let source = try path([.move, verb, .line], [.zero, .zero, .zero, p(10, 0)])
            let result = try outline(source, cap: .square, join: .bevel)
            #expect(result.points.contains(p(2, 0)))
            #expect(line.points.contains(p(2, 0)) == false)
        }
    }

    /// 短Line被丢后看似全零的曲线以最近接受点重新分类，因此得到水平短边而非默认法线。
    @Test func reducedCurveUsesAcceptedRatherThanIteratedStart() throws {
        let small = p(1.0 / 65536, 0)
        for verb in curves {
            let source = try path([.move, .line, verb, .line], [.zero, small, small, small, p(10, 0)])
            let result = try outline(source, cap: .square, join: .bevel)
            #expect(result.points.contains(p(0, -2)))
            #expect(result.points.contains(p(2, 0)) == false)
        }
    }

    /// 原末Quad/Conic即使降为Line或被跳过，Square末帽仍保留端点并追加三条边。
    @Test func originalQuadraticVerbControlsEndCap() throws {
        let line = try outline(path([.move, .line], [.zero, p(10, 0)]), cap: .square)
        for verb in curves {
            for source in try [path([.move, verb], [.zero, p(10, 0), p(10, 0)]),
                               path([.move, .line, verb], [.zero, p(10, 0), p(10, 0), p(10, 0)])] {
                let result = try outline(source, cap: .square)
                #expect(result.points.count == line.points.count + 2)
                #expect(result.points.contains(p(10, -2)) && result.points.contains(p(10, 2)))
                #expect(abs(GeometryTestSupport.area(try mesh(result)) - 56) < 1e-8)
            }
        }
    }

    /// 曲线直接回起点时Close按非Line补after点，自动闭合Line即使被丢也改原verb标记。
    @Test func closedSeamKeepsTheOriginalVerbMarker() throws {
        let small = p(1.0 / 65536, 0)
        for verb in curves {
            let exact = try path([.move, .line, .line, verb, .close], [.zero, p(10, 0), p(0, 10), .zero, .zero])
            let automatic = try path(exact.verbs, [.zero, p(10, 0), p(0, 10), small, small])
            let a = try outline(exact), b = try outline(automatic)
            #expect(a.points.contains(p(-2, -2)))
            #expect(a.points.filter { $0 == p(0, -2) }.count == 2)
            #expect(b.points.count == a.points.count - 1)
        }
    }

    /// 共线回折只在第二条内部边临时Round；面积为往返矩形加半圆，外部Bevel不被改变。
    @Test func reversalsUseRoundOnlyForTheInternalTurn() throws {
        for (verb, turn): (StrokePathVerb, Double) in [(.quad, 2), (.conic(weight: 0.5), Double(Float(4.0 / 3)))] {
            let source = try path([.move, verb], [.zero, p(4, 0), .zero])
            for join in [SourceLineJoin.miter, .bevel, .round] {
                let mesh = try mesh(outline(source, join: join))
                #expect(abs(GeometryTestSupport.area(mesh) - (4 * turn + 2 * Double.pi)) < 0.02)
                #expect(GeometryTestSupport.coverage(mesh, at: p(-1, 0.17)) == 0)
                #expect(GeometryTestSupport.coverage(mesh, at: p(turn + 1, 0.17)) == 1)
            }
            let next = try path([.move, verb, .line], [.zero, p(4, 0), .zero, p(0, 10)])
            #expect(GeometryTestSupport.coverage(try mesh(outline(next, join: .bevel)), at: p(-1.2, -1.3)) == 0)
        }
    }

    /// 真Quad后接Line的miter保留Q末点，不能套用前段Line的覆盖末点操作。
    @Test func quadraticThenLinePreservesCurveEndpointAtMiter() throws {
        var budget = try GeometryBudget()
        let output = try StrokePathOutput(budget: &budget, limits: .standard)
        let state = StrokeContour(first: .zero, radius: 1, cap: .butt, join: .miter, miter: 4)
        try state.quad(control: SIMD2(0, 4), end: SIMD2(4, 4), output: output)
        try state.line(to: SIMD2(4, 8), hasFutureTangent: false, output: output)
        try state.outer.emit(reversed: false, restoration: .identity, tolerance: 0.001, output: output)
        try expect(output.finish(), start: p(1, 0), steps: [
            .quad(p(1, 3), p(4, 3)), .line(p(5, 3)), .line(p(5, 8))])
    }

    /// 真Conic后接Quad保留前曲线、miter和后曲线的首offset，统一闭合输出而不补独立圆盘。
    @Test func conicThenQuadraticKeepsBothCurveEndpoints() throws {
        var budget = try GeometryBudget()
        let output = try StrokePathOutput(budget: &budget, limits: .standard)
        let state = StrokeContour(first: SIMD2(1, 0), radius: 1, cap: .butt, join: .miter, miter: 4)
        try state.conic(control: SIMD2(1, 1), end: SIMD2(0, 1), weight: Float(bitPattern: 0x3F3504F3), output: output)
        try state.quad(control: SIMD2(0, -3), end: SIMD2(-4, -3), output: output)
        try state.outer.emit(reversed: false, restoration: .identity, tolerance: 0.001, output: output)
        try expect(output.finish(), start: p(2, 0), steps: [
            .quad(p(2, 2), p(0, 2)), .line(p(-1, 2)), .line(p(-1, 1)), .quad(p(-1, -2), p(-4, -2))])
    }

    /// 两类真正曲线在同一候选内成功，恢复矩阵只作用一次且不引入Cubic尖点轮廓。
    @Test func mixedContoursRestoreExactlyOnceWithoutCuspCircles() throws {
        let source = try path([.move, .quad, .move, .conic(weight: Float(bitPattern: 0x3F3504F3))],
                              [.zero, p(0, 4), p(4, 4), p(11, 0), p(11, 1), p(10, 1)])
        let matrix = try SceneAffine(a: -2, b: 0, c: 0, d: 3, tx: 100, ty: 200)
        let result = try outline(source, width: 2, matrix: matrix)
        #expect(result.verbs.filter { $0 == .move }.count == 2)
        #expect(result.verbs.filter { $0 == .close }.count == 2)
        #expect(result.points.first == p(98, 200))
        #expect(result.points.contains(p(76, 200)) && result.points.contains(p(80, 206)))
        #expect(GeometryTestSupport.coverage(try mesh(result), at: p(77, 201)) == 1)
    }

    /// 成功Line轮廓之后的Conic数值或递归失败必须抛错，预算已耗但不返回前缀。
    @Test func failuresAfterCompletedContourNeverPublishPrefix() throws {
        let verbs: [StrokePathVerb] = [.move, .line, .move, .conic(weight: Float(bitPattern: 0x3F3504F3))]
        let source = try path(verbs, [p(-10, 0), p(-5, 0), p(1, 0), p(1, 1), p(0, 1)])
        var shallow = try GeometryBudget(maximumDepth: 0)
        #expect(throws: PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")) {
            try StrokeOutline.make(source, style: style(width: 16), tolerance: 0.001, budget: &shallow)
        }
        let overflow = try path([.move, .line, .move, .conic(weight: .greatestFiniteMagnitude)],
                                [p(-10, 0), p(-5, 0), p(1, 0), p(1, 1), p(0, 1)])
        var budget = try GeometryBudget()
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try StrokeOutline.make(overflow, style: style(width: 2), tolerance: 0.001, budget: &budget)
        }
        #expect(budget.work > 40)
    }

    /// 两类三点曲线共用状态测试；权重0.5区别于会规范化为Quad的权重1。
    private var curves: [StrokePathVerb] { [.quad, .conic(weight: 0.5)] }

    /// 源偏移的独立Line/Q序列，最终仅用恒等升阶构造期望。
    private enum Step {
        /// 直边终点，包括源保留的零Line。
        case line(ScenePoint)
        /// 普通二次的控制点和终点，不调用生产偏移器求答案。
        case quad(ScenePoint, ScenePoint)
    }

    /// 根据独立整数Q期望做2/3代数升阶，检查完整轮廓次序及最终Close。
    private func expect(_ actual: SourcePath, start: ScenePoint, steps: [Step]) throws {
        var verbs: [SourcePathVerb] = [.move], points = [start], previous = start
        for step in steps {
            switch step {
            case .line(let end): verbs.append(.line); points.append(end); previous = end
            case .quad(let control, let end):
                verbs.append(.cubic)
                points.append(p(previous.x + (control.x - previous.x) * (2.0 / 3), previous.y + (control.y - previous.y) * (2.0 / 3)))
                points.append(p(end.x + (control.x - end.x) * (2.0 / 3), end.y + (control.y - end.y) * (2.0 / 3)))
                points.append(end)
                previous = end
            }
        }
        verbs.append(.close)
        #expect(actual.verbs == verbs)
        try #require(actual.points.count == points.count)
        for (a, b) in zip(actual.points, points) {
            #expect(abs(a.x - b.x) < 1e-12 && abs(a.y - b.y) < 1e-12)
        }
    }

    /// 独立准备预算发布规范化临时路径，不增加生产旧输入兼容桥。
    private func path(_ verbs: [StrokePathVerb], _ points: [ScenePoint]) throws -> StrokePath {
        var budget = try GeometryBudget()
        return try StrokePath(verbs: verbs, points: points, budget: &budget)
    }

    /// 手算测试默认半宽2，无dash，完整候选共用同一预算。
    private func style(width: Double = 4, cap: SourceLineCap = .butt, join: SourceLineJoin = .miter) -> StrokeStyle {
        StrokeStyle(width: width, cap: cap, join: join, miterLimit: 4, dashes: nil)
    }

    /// 通过生产完整入口核对分流、轮廓状态及最终复原，不绕过接纳检查。
    private func outline(_ path: StrokePath, width: Double = 4, cap: SourceLineCap = .butt,
                         join: SourceLineJoin = .miter, matrix: SceneAffine = .identity) throws -> SourcePath {
        var budget = try GeometryBudget()
        return try StrokeOutline.make(path, style: style(width: width, cap: cap, join: join), restoration: matrix,
                                      tolerance: 0.0005, budget: &budget)
    }

    /// 最终SourcePath经真实nonzero网格核对解析面积和单次覆盖。
    private func mesh(_ path: SourcePath) throws -> RenderMesh {
        var budget = try GeometryBudget()
        return try GeometryTestSupport.mesh(PathFlattening.sourcePath(path, tolerance: 0.001, budget: &budget))
    }

    /// 显式解析坐标，不复用生产曲线求值生成期望。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }
}
