import Testing
@testable import pag_swift

/// 以解析区域验证实线描边、端帽、接角和绕序；不把CG描边结果自身当作期望值。
struct StrokeOutlineTests {
    /// 水平线三种端帽有独立面积与角点判据，开放路径不被隐式闭合后再描边。
    @Test func openLineCapsMatchAnalyticRegions() throws {
        let path = try strokePath(verbs: [.move, .line], points: [.zero, p(10, 0)])
        for cap in [SourceLineCap.butt, .round, .square] {
            let mesh = try mesh(path, cap: cap)
            let area = cap == .butt ? 40 : cap == .square ? 56 : 40 + 4 * Double.pi
            #expect(abs(GeometryTestSupport.area(mesh) - area) < 0.02)
            #expect(GeometryTestSupport.coverage(mesh, at: p(5, 1.7)) == 1)
            #expect(GeometryTestSupport.coverage(mesh, at: p(-1.8, 1.8)) == (cap == .square ? 1 : 0))
            #expect(GeometryTestSupport.coverage(mesh, at: p(-1, 0.2)) == (cap == .butt ? 0 : 1))
        }
    }

    /// Move本身不补端帽；MoveClose、零Line和零Cubic的round/square得到圆点/轴向方点，Butt为空。
    @Test func degenerateContoursUseSourcePointCaps() throws {
        let point = p(5, 7)
        for verbs: [StrokePathVerb] in [[.move], [.move, .close], [.move, .line], [.move, .cubic, .close]] {
            let path = try strokePath(verbs: verbs, points: Array(repeating: point, count: verbs.reduce(0) { $0 + $1.pointCount }))
            for cap in [SourceLineCap.butt, .round, .square] {
                let mesh = try mesh(path, cap: cap)
                if verbs.count == 1 || cap == .butt {
                    #expect(mesh.vertices.isEmpty)
                } else {
                    let area = cap == .round ? 4 * Double.pi : 16
                    #expect(abs(GeometryTestSupport.area(mesh) - area) < 0.02)
                    #expect(GeometryTestSupport.coverage(mesh, at: p(6.8, 8.8)) == (cap == .square ? 1 : 0))
                    #expect(GeometryTestSupport.coverage(mesh, at: p(7.5, 7.1)) == 0)
                }
            }
        }
    }

    /// 闭合两点往返具有真实长度，结果只受join影响；改变cap不能把它变成两个开放端点。
    @Test func closedReturnUsesJoinsRatherThanCaps() throws {
        let path = try strokePath(verbs: [.move, .line, .close], points: [.zero, p(10, 0)])
        for join in [SourceLineJoin.miter, .bevel, .round] {
            for cap in [SourceLineCap.butt, .round, .square] {
                let mesh = try mesh(path, cap: cap, join: join)
                let expected = join == .round ? 40 + 4 * Double.pi : 40
                #expect(abs(GeometryTestSupport.area(mesh) - expected) < 0.02, "join=\(join) cap=\(cap) actual=\(GeometryTestSupport.area(mesh))")
                #expect(GeometryTestSupport.coverage(mesh, at: p(-1, 0.2)) == (join == .round ? 1 : 0))
            }
        }
    }

    /// 直角外侧以独立解析点区分Miter、Round与Bevel，并核对miter限值实际截断。
    @Test func joinsAndMiterThresholdMatchAnalyticCorner() throws {
        let path = try strokePath(verbs: [.move, .line, .line], points: [p(0, 10), .zero, p(10, 0)])
        for join in [SourceLineJoin.miter, .round, .bevel] {
            let mesh = try mesh(path, cap: .butt, join: join)
            #expect(GeometryTestSupport.coverage(mesh, at: p(-1.8, -1.8)) == (join == .miter ? 1 : 0))
            #expect(GeometryTestSupport.coverage(mesh, at: p(-1.2, -1.2)) == (join == .bevel ? 0 : 1))
        }
        let clipped = try mesh(path, cap: .butt, join: .miter, miter: 1.2)
        #expect(GeometryTestSupport.coverage(clipped, at: p(-1.2, -1.2)) == 0)
    }

    /// 点端帽与其他外轮廓必须绕序一致；重叠时既不挖洞，也不生成两次覆盖。
    @Test func overlappingLineAndPointContoursDoNotOverdraw() throws {
        for reversed in [false, true] {
            let path = try strokePath(verbs: [.move, .line, .move, .line],
                points: [p(reversed ? 10 : 0, 0), p(reversed ? 0 : 10, 0), p(5, 0), p(5, 0)])
            for cap in [SourceLineCap.round, .square] {
                let mesh = try mesh(path, cap: cap)
                #expect(abs(GeometryTestSupport.area(mesh) - (cap == .round ? 40 + 4 * Double.pi : 56)) < 0.02)
                #expect(GeometryTestSupport.coverage(mesh, at: p(5.1, 0.3)) == 1)
            }
        }
    }

    /// 所有输出统一复原paint矩阵，反射和非均匀缩放不改变轮廓间的nonzero关系。
    @Test func restorationAppliesToEveryContour() throws {
        let path = try strokePath(verbs: [.move, .line, .move, .close], points: [.zero, p(10, 0), p(5, 0)])
        let matrix = try SceneAffine(a: -2, b: 0, c: 0, d: 3, tx: 100, ty: 200)
        let mesh = try mesh(path, cap: .square, matrix: matrix)
        #expect(abs(GeometryTestSupport.area(mesh) - 56 * 6) < 1e-8)
        #expect(GeometryTestSupport.coverage(mesh, at: p(90, 201)) == 1)
        #expect(GeometryTestSupport.coverage(mesh, at: p(75, 200)) == 0)
    }

    /// 极小正宽走中心线fill，不生成设备一像素线或任何圆端点。
    @Test func hairlineKeepsCenterlineAsFill() throws {
        let path = try strokePath(verbs: [.move, .line, .line, .close], points: [.zero, p(10, 0), p(0, 10)])
        let mesh = try mesh(path, width: 1.0 / 4096, cap: .round)
        #expect(abs(GeometryTestSupport.area(mesh) - 50) < 1e-8)
        let point = try strokePath(verbs: [.move, .line], points: [.zero, .zero])
        #expect(try self.mesh(point, width: 1.0 / 4096, cap: .round).vertices.isEmpty)
    }

    /// 描边入口只接受已经处理dash的中心线，输入、实际输出和共同预算超限都明确失败。
    @Test func inputOutputAndSharedBudgetsFailExplicitly() throws {
        let path = try strokePath(verbs: [.move, .line], points: [.zero, p(10, 0)])
        var budget = try GeometryBudget()
        let dash = try #require(try StrokeDashPattern.make(intervals: [0, 10], phase: 0))
        #expect(throws: PAGError.invalidArgument("strokeRequiresDashedCenterline")) {
            try StrokeOutline.make(path, style: StrokeStyle(width: 4, cap: .round, join: .round, miterLimit: 4, dashes: dash),
                                   tolerance: 0.01, budget: &budget)
        }
        for (limits, name) in [(try StrokeBackendLimits(maximumInputVerbs: 1), "maximumStrokeInputVerbs"),
                              (try StrokeBackendLimits(maximumOutputElements: 2), "maximumStrokeOutputElements")] {
            #expect(throws: PAGError.resourceLimitExceeded(name)) {
                try outline(path, limits: limits, budget: &budget)
            }
        }
        var tiny = try GeometryBudget(maximumBytes: 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) { try outline(path, budget: &tiny) }
    }

    /// 后台并发调用只共享不可变中心线；取消的调用不发布轮廓，不影响另一份独立输出。
    @Test func concurrentOutputsAndCancellationRemainIndependent() async throws {
        let path = try strokePath(verbs: [.move, .line], points: [.zero, p(10, 0)])
        let outputs = try await withThrowingTaskGroup(of: SourcePath.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    var budget = try GeometryBudget()
                    return try outline(path, budget: &budget)
                }
            }
            var values: [SourcePath] = []
            for try await value in group { values.append(value) }
            return values
        }
        try #require(outputs.count == 4)
        #expect(outputs.allSatisfy { $0.verbs == outputs[0].verbs && $0.points == outputs[0].points })
        let task = Task {
            var budget = try GeometryBudget()
            withUnsafeCurrentTask { $0?.cancel() }
            return try outline(path, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 明示解析点坐标，不通过系统路径求边界。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }

    /// 仅生成有界实线轮廓，供预算、取消和并发用例共用。
    private func outline(_ path: StrokePath, limits: StrokeBackendLimits = .standard,
                         budget: inout GeometryBudget) throws -> SourcePath {
        try StrokeOutline.make(path, style: StrokeStyle(width: 4, cap: .round, join: .miter, miterLimit: 4, dashes: nil),
                               tolerance: 0.0005, limits: limits, budget: &budget)
    }

    /// 经过真实轮廓、既有折线化和nonzero分解，测试整条矢量链而非只检查系统bounds。
    private func mesh(_ path: StrokePath, width: Double = 4, cap: SourceLineCap = .butt,
                      join: SourceLineJoin = .miter, miter: Double = 4, matrix: SceneAffine = .identity) throws -> RenderMesh {
        var budget = try GeometryBudget()
        let result = try StrokeOutline.make(path, style: StrokeStyle(width: width, cap: cap, join: join, miterLimit: miter, dashes: nil),
                                           restoration: matrix, tolerance: 0.0005, budget: &budget)
        let contours = try PathFlattening.sourcePath(result, tolerance: 0.001, budget: &budget)
        return try GeometryTestSupport.mesh(contours)
    }
    /// 用独立准备预算发布规范化描边输入，不给生产入口添加旧SourcePath兼容桥。
    private func strokePath(verbs: [StrokePathVerb], points: [ScenePoint]) throws -> StrokePath {
        var budget = try GeometryBudget()
        return try StrokePath(verbs: verbs, points: points, budget: &budget)
    }

}
