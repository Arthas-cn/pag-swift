import Testing
@testable import pag_swift

/// hairline最终填充出口保留拓扑与Double精度，只在此处把临时Quad/Conic转换为SourcePath。
struct StrokeFillPathTests {
    /// 原Move、零Line、Cubic、Close和尾随Move逐一保留，开放轮廓不被出口补Close。
    @Test func preservesLinearCubicAndEmptyContourTopology() throws {
        let verbs: [StrokePathVerb] = [.move, .line, .cubic, .close, .move, .move, .close, .move]
        let points: [ScenePoint] = [.zero, .zero, p(1, 2), p(3, 4), p(5, 6), p(9, 8), p(7, 6), p(4, 3)]
        let result = try fill(path(verbs, points))
        #expect(result.verbs == [.move, .line, .cubic, .close, .move, .move, .close, .move])
        #expect(result.points == points)
    }

    /// 普通Quad仅代数升阶，控制点的小数不能先舍入为Float后再填充。
    @Test func quadraticDegreeElevationRetainsDoubleCoordinates() throws {
        let delta = 1.0 / 1_073_741_824
        let source = try path([.move, .quad], [p(delta, 0), p(3 + delta, 6), p(6 + delta, 0)])
        let result = try fill(source)
        #expect(result.verbs == [.move, .cubic])
        try expectPoints(result.points, [p(delta, 0), p(2 + delta, 4), p(4 + delta, 4), p(6 + delta, 0)])
        #expect(result.points[1].x != Double(Float(2 + delta)))
    }

    /// Quad和Conic零曲线仍输出曲线指令；不会把它们删掉或按端帽生成面积。
    @Test func degenerateCurvesAreNotPointCaps() throws {
        let result = try fill(path([.move, .quad, .conic(weight: 0.5), .close], Array(repeating: p(2, 3), count: 5)))
        #expect(result.verbs == [.move, .cubic, .cubic, .close])
        #expect(result.points == Array(repeating: p(2, 3), count: 7))
    }

    /// 源Float权重的四分圆在出口转成三次；用独立圆域面积与端点顺序核实有理弧未变成折线。
    @Test func conicQuarterReachesFinalFillWithAnalyticArea() throws {
        let result = try fill(path([.move, .conic(weight: Float(bitPattern: 0x3F3504F3)), .line, .close],
                                  [p(1, 0), p(1, 1), p(0, 1), .zero]), tolerance: 0.000_001)
        #expect(result.verbs.first == .move && result.verbs.last == .close)
        #expect(result.verbs.contains(.cubic))
        #expect(result.points.first == p(1, 0) && result.points.dropLast().last == p(0, 1))
        var budget = try GeometryBudget()
        let mesh = try GeometryTestSupport.mesh(PathFlattening.sourcePath(result, tolerance: 0.000_01, budget: &budget))
        // Float(sqrt(1/2))与理想圆的差小于此解析验收容差，不要求两者逐点相等。
        #expect(abs(GeometryTestSupport.area(mesh) - Double.pi / 4) < 0.000_05)
        #expect(GeometryTestSupport.coverage(mesh, at: p(0.6, 0.6)) == 1)
        #expect(GeometryTestSupport.coverage(mesh, at: p(0.8, 0.8)) == 0)
    }

    /// append只用restoration评估误差，最终finish才统一变换；反射、缩放和平移不能应用两次。
    @Test func restorationIsAppliedExactlyOnce() throws {
        let source = try path([.move, .quad], [.zero, p(3, 6), p(6, 0)])
        let matrix = try SceneAffine(a: -2, b: 0, c: 0, d: 3, tx: 10, ty: 20)
        let result = try fill(source, matrix: matrix)
        try expectPoints(result.points, [p(10, 20), p(6, 32), p(2, 32), p(-2, 20)])
        #expect(result.verbs == [.move, .cubic])
    }

    /// 真正StrokeOutline的hairline分支消费Quad/Conic，不生成扩张轮廓或额外端帽。
    @Test func outlineHairlineUsesFinalCurveConversion() throws {
        let source = try path([.move, .quad, .conic(weight: 0.5), .close, .move],
                              [.zero, p(3, 6), p(6, 0), p(3, -6), .zero, p(9, 9)])
        var budget = try GeometryBudget()
        let result = try StrokeOutline.make(source,
            style: StrokeStyle(width: 1.0 / 4096, cap: .round, join: .round, miterLimit: 4, dashes: nil),
            tolerance: 0.001, budget: &budget)
        #expect(result.verbs.filter { $0 == .move }.count == 2)
        #expect(result.verbs.filter { $0 == .close }.count == 1)
        #expect(result.verbs.contains(.line) == false)
        #expect(result.verbs.last == .move && result.points.last == p(9, 9))
        try expectPoints(Array(result.points.prefix(4)), [.zero, p(2, 4), p(4, 4), p(6, 0)])
    }

    /// 低深度、实际输出与工作预算都可中止出口，已完成的Line前缀不能变成返回值。
    @Test func limitsRejectTheEntireFinalCandidate() throws {
        let source = try path([.move, .line, .move, .conic(weight: Float(bitPattern: 0x3F3504F3))],
                              [p(-2, 0), p(-1, 0), p(1, 0), p(1, 1), p(0, 1)])
        #expect(throws: PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")) {
            try fill(source, tolerance: 0.000_001, budget: GeometryBudget(maximumDepth: 0))
        }
        #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeOutputElements")) {
            try fill(source, limits: StrokeBackendLimits(maximumOutputElements: 2))
        }
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try fill(source, budget: GeometryBudget(maximumWork: 10))
        }
    }

    /// 空路径也验证容差与取消，不能以没有曲线为由绕过统一失败语义。
    @Test func emptyInputStillChecksInvalidToleranceAndCancellation() async throws {
        let source = try path([], [])
        for tolerance in [0.0, -.infinity, .nan] {
            #expect(throws: PAGError.invalidArgument("geometryTolerance")) { try fill(source, tolerance: tolerance) }
        }
        #expect(try fill(source).verbs.isEmpty)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try fill(source)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 独立准备预算构造不可变输入，和本次输出工作预算分开。
    private func path(_ verbs: [StrokePathVerb], _ points: [ScenePoint]) throws -> StrokePath {
        var budget = try GeometryBudget()
        return try StrokePath(verbs: verbs, points: points, budget: &budget)
    }

    /// 只在完整append和finish成功后发布SourcePath，所有临时增长使用同一输出预算。
    private func fill(_ path: StrokePath, matrix: SceneAffine = .identity, tolerance: Double = 0.001,
                      budget: GeometryBudget? = nil, limits: StrokeBackendLimits = .standard) throws -> SourcePath {
        var budget = try budget ?? GeometryBudget()
        let output = try StrokePathOutput(budget: &budget, limits: limits)
        try StrokeFillPath.append(path, restoration: matrix, tolerance: tolerance, to: output)
        return try output.finish(restoring: matrix)
    }

    /// 只比较独立代数点，容许Double等价升阶的末位舍入。
    private func expectPoints(_ actual: [ScenePoint], _ expected: [ScenePoint]) throws {
        try #require(actual.count == expected.count)
        for (a, b) in zip(actual, expected) {
            #expect(abs(a.x - b.x) < 1e-12 && abs(a.y - b.y) < 1e-12)
        }
    }

    /// 明示解析点，不经过生产采样器或矩阵生成期望。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }
}
