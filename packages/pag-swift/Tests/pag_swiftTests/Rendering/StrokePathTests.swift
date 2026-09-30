import Testing
@testable import pag_swift

/// 临时描边值模型的结构、权重规范化及失败预算；不构造PAG字节或声称消费者已接入。
struct StrokePathTests {
    /// 混合曲线保留独立verb与Double点，不把Conic拆成Cubic或删除重复端点。
    @Test func mixedCurvesPreserveTypesAndCoordinates() throws {
        let verbs: [StrokePathVerb] = [.move, .line, .quad, .conic(weight: 0.5), .cubic, .close, .move]
        let points = (0..<10).map { ScenePoint(x: Double($0) / 3, y: Double($0) / 7) }
        var budget = try GeometryBudget()
        let path = try StrokePath(verbs: verbs, points: points, budget: &budget)
        #expect(path.verbs == verbs && path.points == points)
        #expect(path.points[1].x != Double(Float(path.points[1].x)))
        #expect(budget.work == 18)
    }

    /// 真实Conic短截取可产生单位权重；归为Quad后点索引不变，其他正有限权重逐位保留。
    @Test func unitWeightBecomesQuadWithoutMovingPoints() throws {
        let points = [ScenePoint(x: 1, y: 0), ScenePoint(x: 1, y: 0.00017264584312215447),
                      ScenePoint(x: 0.9999999403953552, y: 0.0003452916571404785)]
        var budget = try GeometryBudget()
        let path = try StrokePath(verbs: [.move, .conic(weight: 1)], points: points, budget: &budget)
        #expect(path.verbs == [.move, .quad] && path.points == points)
        for weight in [Float.leastNonzeroMagnitude, Float(0.707106781), Float.greatestFiniteMagnitude] {
            let retained = try StrokePath(verbs: [.move, .conic(weight: weight)], points: points, budget: &budget)
            #expect(retained.verbs == [.move, .conic(weight: weight)])
        }
    }

    /// 空值、连续或尾随Move、Move直接Close都合法，不因无填充面积删除其拓扑。
    @Test func emptyAndDegenerateContoursRemainRepresentable() throws {
        let cases: [[StrokePathVerb]] = [[], [.move], [.move, .move], [.move, .close],
            [.move, .close, .move], [.move, .line, .close, .move, .quad]]
        for verbs in cases {
            var budget = try GeometryBudget()
            let points = Array(repeating: ScenePoint.zero, count: verbs.reduce(0) { $0 + $1.pointCount })
            let path = try StrokePath(verbs: verbs, points: points, budget: &budget)
            #expect(path.verbs == verbs && path.points == points)
        }
    }

    /// 绘制或Close缺少开放Move、Close后继续绘制或重复Close都失败，不能自动修补另一条路径。
    @Test func missingOpenContourIsRejected() throws {
        let cases: [[StrokePathVerb]] = [[.line], [.quad], [.conic(weight: 0.5)], [.cubic], [.close],
            [.move, .close, .line], [.move, .close, .quad], [.move, .close, .conic(weight: 0.5)],
            [.move, .close, .cubic], [.move, .close, .close]]
        for verbs in cases {
            var budget = try GeometryBudget()
            let points = Array(repeating: ScenePoint.zero, count: verbs.reduce(0) { $0 + $1.pointCount })
            #expect(throws: PAGError.invalidArgument("strokePathSequence")) {
                try StrokePath(verbs: verbs, points: points, budget: &budget)
            }
        }
    }

    /// 缺失或多余点均拒绝；合法前缀不允许剩余点被静默忽略。
    @Test func pointArityMustMatchExactly() throws {
        for count in [0, 2, 4] {
            var budget = try GeometryBudget()
            #expect(throws: PAGError.invalidArgument("strokePathPoints")) {
                try StrokePath(verbs: [.move, .quad], points: Array(repeating: .zero, count: count), budget: &budget)
            }
        }
    }

    /// 非正和非有限权重不复制源损坏输入转Line的修复分支，统一明确失败。
    @Test(arguments: [Float(0), -0.0, -1, .nan, .infinity, -.infinity])
    func invalidWeightsDoNotBecomeLines(_ weight: Float) throws {
        var budget = try GeometryBudget()
        #expect(throws: PAGError.invalidArgument("strokeConicWeight")) {
            try StrokePath(verbs: [.move, .conic(weight: weight)], points: [.zero, .zero, .zero], budget: &budget)
        }
    }

    /// 两个坐标方向的非有限点都拒绝；数值错误与指令布局错误保持不同原因。
    @Test func nonFiniteCoordinatesAreRejected() throws {
        for point in [ScenePoint(x: .nan, y: 0), ScenePoint(x: 0, y: .infinity), ScenePoint(x: -.infinity, y: 0)] {
            var budget = try GeometryBudget()
            #expect(throws: PAGError.invalidArgument("strokePathPoint")) {
                try StrokePath(verbs: [.move], points: [point], budget: &budget)
            }
        }
    }

    /// 存储成本边界精确接受，少一字节或工作量不足失败，并保留失败前已消费的工作。
    @Test func budgetChecksPrecedePublication() throws {
        let verbs: [StrokePathVerb] = [.move, .line], points: [ScenePoint] = [.zero, .zero]
        // 对象128、两个verb各16、两个点各32，共224；工作为入口1加指令2加点2。
        var exact = try GeometryBudget(maximumBytes: 224, maximumWork: 5)
        #expect(try StrokePath(verbs: verbs, points: points, budget: &exact).verbs == verbs)
        var bytes = try GeometryBudget(maximumBytes: 223)
        try bytes.consume(7)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try StrokePath(verbs: verbs, points: points, budget: &bytes)
        }
        #expect(bytes.work == 8)
        var work = try GeometryBudget(maximumWork: 4)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try StrokePath(verbs: verbs, points: points, budget: &work)
        }
        #expect(work.work == 4)
    }

    /// 发布值可跨任务共享，调用方之后修改输入数组不会改变已保存的几何快照。
    @Test func inputMutationsDoNotChangeConcurrentSnapshots() async throws {
        var verbs: [StrokePathVerb] = [.move, .conic(weight: 1)]
        var points: [ScenePoint] = [.zero, .init(x: 1, y: 2), .init(x: 3, y: 4)]
        var budget = try GeometryBudget()
        let path = try StrokePath(verbs: verbs, points: points, budget: &budget)
        verbs[1] = .line
        points[1] = .zero
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 {
                group.addTask { path.verbs == [.move, .quad] && path.points[1] == ScenePoint(x: 1, y: 2) }
            }
            for await unchanged in group { #expect(unchanged) }
        }
    }

    /// 即使输入为空，进入构造前的取消也必须传播，不能发布看似成功的空路径。
    @Test func cancellationRejectsEmptyInput() async throws {
        let task = Task {
            var budget = try GeometryBudget()
            withUnsafeCurrentTask { $0?.cancel() }
            return try StrokePath(verbs: [], points: [], budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
