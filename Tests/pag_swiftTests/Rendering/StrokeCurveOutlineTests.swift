import Testing
@testable import pag_swift

/// 完整混合描边的源码独立期望，验证接角、首末帽、尖点和实际非zero填充。
struct StrokeCurveOutlineTests {
    /// 被跳过的极短Line不推进接受点，随后真正Cubic必须与直接从Move开始的结果相同。
    @Test func curveAfterSkippedLineUsesAcceptedStart() throws {
        let source = try arch()
        let path = try strokePath(verbs: [.move, .line, .cubic],
            points: [.zero, p(1.0 / 65536, 0)] + source.points.dropFirst())
        let expected = try outline(source), actual = try outline(path)
        #expect(actual.verbs == expected.verbs && actual.points == expected.points)
    }

    /// preJoin和末帽先单位化再乘半宽；直接用offset ray的半宽归一化会差一个Float舍入。
    @Test func endpointNormalsKeepSourceOperationOrder() throws {
        let path = try strokePath(verbs: [.move, .cubic], points: [.zero, p(1, 2), p(3, 4), p(4, 6)])
        let result = try outline(path, width: 6, cap: .square)
        #expect(result.points.first == p(2.683281421661377, -1.3416407108306885))
        #expect(result.points.contains(p(8.024922370910645, 7.341640949249268)))
        #expect(result.points.contains(p(2.6583592891693115, 10.024921417236328)))
    }

    /// 原始末Line虽被跳过仍改变末Square帽；起帽继续使用最近成功Cubic类型。
    @Test func skippedLastLineChangesOnlyTheEndCapMode() throws {
        let source = try arch()
        let line = try strokePath(verbs: source.verbs + [.line], points: source.points + [p(4, 0)])
        let normal = try outline(source, cap: .square), skipped = try outline(line, cap: .square)
        // 独立源forward序列整体反向；Q的控制点不变，输出器只做代数等价的三次表示。
        try expect(normal, start: p(1, 0), steps: [
            .line(p(1, -1)), .line(p(-1, -1)), .line(p(-1, 0)), .quad(p(-1, 4), p(2, 4)),
            .quad(p(5, 4), p(5, 0)), .line(p(5, -1)), .line(p(3, -1)), .line(p(3, 0)),
            .quad(p(3, 2), p(2, 2)), .quad(p(1, 2), p(1, 0))])
        try expect(skipped, start: p(1, 0), steps: [
            .line(p(1, -1)), .line(p(-1, -1)), .line(p(-1, 0)), .quad(p(-1, 4), p(2, 4)),
            .quad(p(5, 4), p(5, -1)), .line(p(3, -1)), .quad(p(3, 2), p(2, 2)), .quad(p(1, 2), p(1, 0))])
    }

    /// Cubic后接Line的miter保留原Q末点，追加交点但不额外追加after点。
    @Test func cubicThenLinePreservesTheCurveEndpoint() throws {
        var outputBudget = try GeometryBudget()
        let output = try StrokePathOutput(budget: &outputBudget, limits: .standard)
        let state = StrokeContour(first: .zero, radius: 1, cap: .butt, join: .miter, miter: 4)
        try state.cubic(first: SIMD2(0, 4), second: SIMD2(4, 4), end: SIMD2(4, 0), output: output)
        try state.line(to: SIMD2(8, 0), hasFutureTangent: false, output: output)
        try expect(emit(state.outer, output: output), start: p(1, 0), steps: [
            .quad(p(1, 2), p(2, 2)), .quad(p(3, 2), p(3, 0)), .line(p(3, -1)), .line(p(8, -1))])
        var innerOutputBudget = try GeometryBudget()
        let innerOutput = try StrokePathOutput(budget: &innerOutputBudget, limits: .standard)
        try expect(emit(state.inner, output: innerOutput), start: p(-1, 0), steps: [
            .quad(p(-1, 4), p(2, 4)), .quad(p(5, 4), p(5, 0)), .line(p(4, 0)), .line(p(4, 1)), .line(p(8, 1))])
    }

    /// Line后接Cubic的miter改写前Line末点，并保留当前Cubic首offset点。
    @Test func lineThenCubicReplacesLineAndAddsAfterPoint() throws {
        var outputBudget = try GeometryBudget()
        let output = try StrokePathOutput(budget: &outputBudget, limits: .standard)
        let state = StrokeContour(first: SIMD2(-4, 0), radius: 1, cap: .butt, join: .miter, miter: 4)
        try state.line(to: .zero, hasFutureTangent: true, output: output)
        try state.cubic(first: SIMD2(0, 4), second: SIMD2(4, 4), end: SIMD2(4, 0), output: output)
        try expect(emit(state.outer, output: output), start: p(-4, -1), steps: [
            .line(p(1, -1)), .line(p(1, 0)), .quad(p(1, 2), p(2, 2)), .quad(p(3, 2), p(3, 0))])
    }

    /// 两个真正Cubic相接时同时保留前曲线末点、miter交点和后曲线首offset。
    @Test func twoCubicsKeepBothCurveEndpoints() throws {
        var outputBudget = try GeometryBudget()
        let output = try StrokePathOutput(budget: &outputBudget, limits: .standard)
        let state = StrokeContour(first: .zero, radius: 1, cap: .butt, join: .miter, miter: 4)
        try state.cubic(first: SIMD2(0, 4), second: SIMD2(4, 4), end: SIMD2(4, 0), output: output)
        try state.cubic(first: SIMD2(8, 0), second: SIMD2(8, 4), end: SIMD2(4, 4), output: output)
        try expect(emit(state.outer, output: output), start: p(1, 0), steps: [
            .quad(p(1, 2), p(2, 2)), .quad(p(3, 2), p(3, 0)), .line(p(3, -1)), .line(p(4, -1)),
            .quad(p(8, -1), p(8, 2)), .quad(p(8, 5), p(4, 5))])
    }

    /// 后继真正Line使起帽使用Line方式，即使最初是Cubic；起帽不能按首段类型固定。
    @Test func firstCapUsesLastAcceptedTypeRatherThanFirstType() throws {
        let curve = try arch()
        let path = try strokePath(verbs: curve.verbs + [.line], points: curve.points + [p(8, 0)])
        let result = try outline(path, cap: .square)
        // 源起帽Line分支将反向inner末Q端点(-1,0)直接改为(-1,-1)。
        #expect(result.points.contains(p(-1, 0)) == false)
        #expect(result.points.contains(p(-1, -1)))
        #expect(result.points.contains(p(9, -1)) && result.points.contains(p(9, 1)))
    }

    /// 末控制点重复时末法线使用P3-P1，Square向右延伸而非复用起始向下方向。
    @Test func repeatedEndControlUsesTheSecondEndTangent() throws {
        let path = try strokePath(verbs: [.move, .cubic], points: [.zero, p(0, 4), p(4, 4), p(4, 4)])
        let result = try outline(path, cap: .square)
        #expect(result.points.contains(p(5, 3)))
        #expect(result.points.contains(p(5, 5)))
        #expect(result.points.contains(p(3, 5)) == false)
    }

    /// 闭合拱的自动Line使用接角，三种cap结果一致，中心孔洞不会被端帽填满。
    @Test func closedCubicUsesSeamJoinAndRetainsHole() throws {
        let source = try arch()
        let closed = try strokePath(verbs: source.verbs + [.close], points: source.points)
        let a = try outline(closed), b = try outline(closed, cap: .round), c = try outline(closed, cap: .square)
        #expect(a.verbs == b.verbs && a.points == b.points)
        #expect(a.verbs == c.verbs && a.points == c.points)
        let mesh = try mesh(a)
        #expect(GeometryTestSupport.coverage(mesh, at: p(2.13, 1.45)) == 0)
        #expect(GeometryTestSupport.coverage(mesh, at: p(2.13, 2.7)) == 1)
    }

    /// cusp圆在主体后追加，按Float边界重算中心；仅靠主体不会覆盖圆的上半伸出区域。
    @Test func cuspCircleUsesRecomputedOvalAndCompoundFill() throws {
        let result = try outline(cusp(), width: 4)
        let moves = movePoints(result)
        try #require(moves.count == 2)
        #expect(moves[1] == p(4, 3))
        #expect(result.points.contains(p(2, 5)))
        #expect(result.points.contains(p(Double(Float(2).nextUp - 2), 3)))
        let mesh = try mesh(result)
        for point in [p(2.13, 4.5), p(1.1, 4.23), p(3.1, 4.23), p(2.173, 2.419)] {
            #expect(GeometryTestSupport.coverage(mesh, at: point) == 1)
        }
        #expect(GeometryTestSupport.coverage(mesh, at: p(2.1, 5.25)) == 0)
    }

    /// 同轮廓的重复尖点圆仍只填充一次，下一无cusp轮廓不得继承这些补圆。
    @Test func multipleCuspsRemainLocalAndDoNotOverdraw() throws {
        let path = try strokePath(verbs: [.move, .cubic, .cubic, .move, .cubic], points: [
            .zero, p(4, 4), p(0, 4), p(4, 0), p(0, 4), p(4, 4), .zero,
            p(20, 0), p(20, 4), p(24, 4), p(24, 0)])
        let result = try outline(path, width: 4)
        #expect(movePoints(result).count == 4)
        let mesh = try mesh(result)
        #expect(GeometryTestSupport.coverage(mesh, at: p(2.13, 4.5)) == 1)
        #expect(GeometryTestSupport.coverage(mesh, at: p(22.13, 5.5)) == 0)
        let matrix = try SceneAffine(a: -2, b: 0, c: 0, d: 3, tx: 30, ty: 40)
        let transformed = try outline(path, width: 4, matrix: matrix)
        let transformedMesh = try self.mesh(transformed)
        #expect(GeometryTestSupport.coverage(transformedMesh, at: p(25.74, 53.5)) == 1)
        #expect(abs(GeometryTestSupport.area(transformedMesh) / 6 - GeometryTestSupport.area(mesh)) < 0.02)
    }

    /// 真实完整入口在已完成另一轮廓后遭遇深度/求根失败，只抛错误，不返回前缀或改走CG。
    @Test func failuresAfterEarlierContourDoNotPublishPartialOutline() throws {
        let source = try arch()
        let path = try strokePath(verbs: [.move, .line] + source.verbs, points: [p(-10, 0), p(-5, 0)] + source.points)
        var shallow = try GeometryBudget(maximumDepth: 0)
        #expect(throws: PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")) {
            try StrokeOutline.make(path, style: style(), tolerance: 0.001, budget: &shallow)
        }
        let overflowing = try strokePath(verbs: [.move, .line, .move, .cubic],
            points: [p(-10, 0), p(-5, 0), .zero, p(8_388_608, 0), p(8_388_608, 0), p(1, 0)])
        var budget = try GeometryBudget()
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try StrokeOutline.make(overflowing, style: style(), tolerance: 0.001, budget: &budget)
        }
        #expect(budget.work > 64)
    }

    /// 独立源quadratic期望的逐段表达，转换为三次只用于比较最终SourcePath。
    private enum Step {
        /// 一条直边，关联值为终点。
        case line(ScenePoint)
        /// 源二次段，关联值依次为控制点与终点。
        case quad(ScenePoint, ScenePoint)
    }

    /// 用已知源控制点的2/3恒等式构造期望，不复用生产偏移/转换器计算参照。
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
        for (actual, expected) in zip(actual.points, points) {
            #expect(abs(actual.x - expected.x) < 1e-12 && abs(actual.y - expected.y) < 1e-12)
        }
    }

    /// 只在验证接角时输出forward边界；完整cap/cusp用例经过正式StrokeOutline入口。
    private func emit(_ boundary: StrokeLineBoundary, output: StrokePathOutput) throws -> SourcePath {
        try boundary.emit(reversed: false, restoration: .identity, tolerance: 0.0005, output: output)
        return try output.finish()
    }

    /// 收集实际Move点以检查轮廓个数及补圆位置，不推断系统bounds。
    private func movePoints(_ path: SourcePath) -> [ScenePoint] {
        var index = 0, result: [ScenePoint] = []
        for verb in path.verbs {
            if verb == .move { result.append(path.points[index]) }
            index += verb.pointCount
        }
        return result
    }

    /// 独立拱形语义输入，半宽1时两侧有已手算的整数quadratic控制点。
    private func arch() throws -> StrokePath { try strokePath(verbs: [.move, .cubic], points: [.zero, p(0, 4), p(4, 4), p(4, 0)]) }

    /// 内部导数为零且首末控制边交叉的已知cusp，不构造PAG二进制。
    private func cusp() throws -> StrokePath { try strokePath(verbs: [.move, .cubic], points: [.zero, p(4, 4), p(0, 4), p(4, 0)]) }

    /// 测试默认半宽1、miter4和无dash，便于独立精确接角期望。
    private func style(width: Double = 2, cap: SourceLineCap = .butt) -> StrokeStyle {
        StrokeStyle(width: width, cap: cap, join: .miter, miterLimit: 4, dashes: nil)
    }

    /// 完整纯Swift生产入口，所有子路径和circle统一复原矩阵后返回。
    private func outline(_ path: StrokePath, width: Double = 2, cap: SourceLineCap = .butt,
                         matrix: SceneAffine = .identity) throws -> SourcePath {
        var budget = try GeometryBudget()
        return try StrokeOutline.make(path, style: style(width: width, cap: cap), restoration: matrix, tolerance: 0.0005, budget: &budget)
    }

    /// 实际nonzero填充后验证覆盖次数，能发现独立圆图元导致的重复alpha区域。
    private func mesh(_ path: SourcePath) throws -> RenderMesh {
        var budget = try GeometryBudget()
        return try GeometryTestSupport.mesh(PathFlattening.sourcePath(path, tolerance: 0.001, budget: &budget))
    }

    /// 解析坐标简写，不调用生产矩阵或求值器。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }
    /// 用独立准备预算发布规范化描边输入，不给生产入口添加旧SourcePath兼容桥。
    private func strokePath(verbs: [StrokePathVerb], points: [ScenePoint]) throws -> StrokePath {
        var budget = try GeometryBudget()
        return try StrokePath(verbs: verbs, points: points, budget: &budget)
    }

}
