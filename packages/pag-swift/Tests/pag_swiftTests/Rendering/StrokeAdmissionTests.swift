import Testing
@testable import pag_swift

/// 后台Swift几何构造前的接纳扫描；期望值来自解析线段与控制多边形，不调用CG测量器。
struct StrokeAdmissionTests {
    /// 开放3–4线段的L1为7，Close后为14；相距很远的独立子路径不计连接距离。
    @Test func lengthsAndRangesRespectOpenClosedSubpaths() throws {
        let path = try makePath(verbs: [.move, .line, .move, .line, .close, .move],
            points: [p(0, 0), p(3, 4), p(100, 100), p(103, 104), p(1000, 1000)])
        let result = try inspect(path)
        try #require(result.subpaths.count == 3)
        let first = result.subpaths[0], second = result.subpaths[1], last = result.subpaths[2]
        #expect(first.lengthUpperBound >= 7 && first.lengthUpperBound < 7.000001)
        #expect(second.lengthUpperBound >= 14 && second.lengthUpperBound < 14.000001)
        #expect(first.verbs == 0..<2 && first.points == 0..<2 && !first.isClosed)
        #expect(second.verbs == 2..<5 && second.points == 2..<4 && second.isClosed)
        #expect(last.verbs == 5..<6 && last.points == 4..<5 && !last.hasSegments && last.lengthUpperBound == 0)
        #expect(result.dashPieceUpperBound == 0)
    }

    /// 首尾相同的回折Cubic仍有非零控制多边形长度，不能以端点弦长零绕过dash成本。
    @Test func cubicUsesAllControlPolygonEdges() throws {
        let path = try makePath(verbs: [.move, .cubic], points: [.zero, p(10, 0), p(-10, 0), .zero])
        let result = try inspect(path, dashes: [0, 10])
        let contour = try #require(result.subpaths.first)
        #expect(contour.lengthUpperBound >= 40 && contour.lengthUpperBound < 40.000001)
        #expect(contour.hasSegments && !contour.isClosed)
        // 向上包围恰在整周期边界可多计一周期；这不是修改实际分段数。
        #expect(result.dashPieceUpperBound >= 6)
    }

    /// Quad与正权重Conic都用完整两边控制多边形接纳，闭合弦为零不能免除虚线成本。
    @Test func quadraticCurvesKeepControlPolygonBounds() throws {
        for verb: StrokePathVerb in [.quad, .conic(weight: 0.5), .conic(weight: 2)] {
            let path = try makePath(verbs: [.move, verb, .close], points: [.zero, p(3, 4), .zero])
            let result = try inspect(path, dashes: [0, 2])
            let contour = try #require(result.subpaths.first)
            #expect(contour.lengthUpperBound >= 14 && contour.lengthUpperBound < 14.000001)
            #expect(contour.verbs == 0..<3 && contour.points == 0..<3 && contour.isClosed)
            #expect(result.dashPieceUpperBound >= 9)
            #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeDashPieces")) {
                try inspect(path, dashes: [0, 2], limits: StrokeBackendLimits(maximumDashPieces: 8))
            }
        }
    }

    /// 纯Move与零Line、零Cubic、MoveClose结构分开保留，接纳计数不替代实际dash消费者。
    @Test func degeneracyRemainsMetadataAndCostsAreConservative() throws {
        let path = try makePath(verbs: [.move, .move, .line, .move, .cubic, .move, .close],
            points: Array(repeating: .zero, count: 8))
        let result = try inspect(path, dashes: [0, 10])
        #expect(result.subpaths.map(\.hasSegments) == [false, true, true, true])
        #expect(result.subpaths.map(\.isClosed) == [false, false, false, true])
        #expect(result.subpaths.allSatisfy { $0.lengthUpperBound == 0 })
        #expect(result.dashPieceUpperBound == 6)
    }

    /// 每个独立轮廓都预留两个周期余量；零on和连续零项不能从每周期片段数删去。
    @Test func dashAllowanceResetsForEveryContourAndKeepsZeroOn() throws {
        let path = try makePath(verbs: [.move, .line, .move, .line], points: [.zero, p(3, 0), p(100, 0), p(103, 0)])
        for intervals in [[0.0, 10], [10.0, 0]] {
            #expect(try inspect(path, dashes: intervals).dashPieceUpperBound == 6)
        }
        #expect(try inspect(path, dashes: [0, 0, 0, 10]).dashPieceUpperBound == 12)
        #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeDashPieces")) {
            try inspect(path, dashes: [0, 10], limits: StrokeBackendLimits(maximumDashPieces: 5))
        }
    }

    /// Float规范化period可能大于真实间隔和；成本分母必须按Double间隔重算而不改变phase。
    @Test func floatPeriodCannotUnderestimateCycleCount() throws {
        let pattern = try #require(try StrokeDashPattern.make(intervals: [16_777_216, 3], phase: 0))
        #expect(pattern.period == 16_777_220)
        let path = try makePath(verbs: [.move, .line], points: [.zero, p(16_777_219.5, 0)])
        var budget = try GeometryBudget()
        let result = try StrokeAdmission.inspect(path, style: style(dashes: pattern),
            limits: StrokeBackendLimits(maximumMagnitude: 33_554_432), budget: &budget)
        #expect(result.dashPieceUpperBound == 4 && pattern.phase == 0)
    }

    /// 极小周期及超过Int可表示范围的商明确失败，不把虚线回落实线或触发转换陷阱。
    @Test func tinyDashPeriodAndIntegerOverflowFail() throws {
        let path = try makePath(verbs: [.move, .line], points: [.zero, p(100, 0)])
        for limit in [32_768, Int.max] {
            #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeDashPieces")) {
                try inspect(path, dashes: [0, Double(Float.leastNonzeroMagnitude)],
                            limits: StrokeBackendLimits(maximumDashPieces: limit))
            }
        }
    }

    /// 接纳范围包含扩张后的包络：斜向square需要sqrt(2)倍半宽，round不读取无关miter。
    @Test func envelopeIncludesSquareAndMiterExpansion() throws {
        let path = try makePath(verbs: [.move, .line], points: [p(7, 0), p(8, 1)])
        var budget = try GeometryBudget()
        let limits = try StrokeBackendLimits(maximumMagnitude: 9.2)
        #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeMagnitude")) {
            try StrokeAdmission.inspect(path, style: style(cap: .square), limits: limits, budget: &budget)
        }
        _ = try StrokeAdmission.inspect(path, style: style(miter: Double.greatestFiniteMagnitude), limits: limits, budget: &budget)
        #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeMagnitude")) {
            try StrokeAdmission.inspect(path, style: style(join: .miter),
                limits: StrokeBackendLimits(maximumMagnitude: 11), budget: &budget)
        }
        _ = try StrokeAdmission.inspect(path, style: style(width: 1.0 / 4096, cap: .square, join: .miter),
            limits: StrokeBackendLimits(maximumMagnitude: 8), budget: &budget)
    }

    /// 输入verbs/points/所有Move和扫描元数据都受上限约束；读取已有数组也要扣工作预算。
    @Test func allInputAndBudgetLimitsAreEnforced() throws {
        let path = try makePath(verbs: [.move, .line, .move], points: [.zero, p(1, 0), p(2, 0)])
        for (limits, name) in [(try StrokeBackendLimits(maximumInputVerbs: 2), "maximumStrokeInputVerbs"),
                              (try StrokeBackendLimits(maximumInputPoints: 2), "maximumStrokeInputPoints"),
                              (try StrokeBackendLimits(maximumSubpaths: 1), "maximumStrokeSubpaths")] {
            #expect(throws: PAGError.resourceLimitExceeded(name)) { try inspect(path, limits: limits) }
        }
        for (initial, name) in [(try GeometryBudget(maximumBytes: 1), "maximumRenderGeometryBytes"),
                               (try GeometryBudget(maximumWork: 1), "maximumRenderGeometryWork")] {
            var budget = initial
            #expect(throws: PAGError.resourceLimitExceeded(name)) {
                try StrokeAdmission.inspect(path, style: style(), budget: &budget)
            }
        }
    }

    /// 模型拒绝初始Line或Close后Line；接纳继续拒绝非法宽度和dash样式。
    @Test func unnormalizedPathsAndInvalidStylesFail() throws {
        for verbs: [StrokePathVerb] in [[.line], [.move, .close, .line], [.close]] {
            #expect(throws: PAGError.invalidArgument("strokePathSequence")) {
                try makePath(verbs: verbs, points: Array(repeating: .zero, count: verbs.reduce(0) { $0 + $1.pointCount }))
            }
        }
        let path = try makePath(verbs: [.move], points: [.zero])
        var budget = try GeometryBudget()
        #expect(throws: PAGError.invalidArgument("strokeStyle")) {
            try StrokeAdmission.inspect(path, style: style(width: 0), budget: &budget)
        }
        let bad = StrokeDashPattern(intervals: [0, 0], phase: 0, period: 1)
        #expect(throws: PAGError.invalidArgument("strokeDashPattern")) {
            try StrokeAdmission.inspect(path, style: style(dashes: bad), budget: &budget)
        }
    }

    /// 零线扰动由中心线完成，接纳读取实际短线长度，不再扰动或把它当零点跳过。
    @Test func admissionUsesAlreadyPerturbedCenterline() throws {
        let source = try SourcePath(verbs: [.move, .line], points: [.zero, .zero])
        let dash = try #require(try StrokeDashPattern.make(intervals: [1, 1], phase: 0))
        let stroke = try ShapeStroke(style: style(dashes: dash), matrix: .identity)
        let geometry = try ShapeGeometry(contours: [.path(source, matrix: .identity)], stroke: stroke)
        var budget = try GeometryBudget()
        let path = try StrokeCenterline.make(geometry, budget: &budget)
        let result = try StrokeAdmission.inspect(path, style: stroke.style, budget: &budget)
        let contour = try #require(result.subpaths.first)
        #expect(contour.lengthUpperBound >= Double(Float(1.001) / 4096) && contour.lengthUpperBound < 0.001)
        #expect(path.points.last?.x == Double(Float(1.001) / 4096) && result.dashPieceUpperBound == 3)
    }

    /// 预取消连空扫描也立即失败，没有可被后端误消费的部分接纳结果。
    @Test func cancellationIsPropagated() async throws {
        let path = try makePath(verbs: [], points: [])
        let task = Task {
            var budget = try GeometryBudget()
            withUnsafeCurrentTask { $0?.cancel() }
            return try StrokeAdmission.inspect(path, style: style(), budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 用独立坐标使各组解析期望可直接阅读。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }

    /// 用独立预算构造已验证输入，接纳测试的预算只包含被测扫描工作。
    private func makePath(verbs: [StrokePathVerb], points: [ScenePoint]) throws -> StrokePath {
        var budget = try GeometryBudget()
        return try StrokePath(verbs: verbs, points: points, budget: &budget)
    }

    /// 创建当前测试明确指定的几何样式，不经过PAG读取或平台API。
    private func style(width: Double = 2, cap: SourceLineCap = .round, join: SourceLineJoin = .round,
                       miter: Double = 4, dashes: StrokeDashPattern? = nil) -> StrokeStyle {
        StrokeStyle(width: width, cap: cap, join: join, miterLimit: miter, dashes: dashes)
    }

    /// 经正式dash规范化后执行接纳扫描，默认限制与生产入口相同。
    private func inspect(_ path: StrokePath, dashes: [Double]? = nil,
                         limits: StrokeBackendLimits = .standard) throws -> StrokeAdmission {
        let pattern = try dashes.flatMap { try StrokeDashPattern.make(intervals: $0, phase: 0) }
        var budget = try GeometryBudget()
        return try StrokeAdmission.inspect(path, style: style(dashes: pattern), limits: limits, budget: &budget)
    }
}
