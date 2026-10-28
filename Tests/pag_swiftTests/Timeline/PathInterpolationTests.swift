import Testing
@testable import pag_swift

/// 路径形变的独立数值、共享端点和失败语义；不把几何插值通过当作已经渲染动画。
struct PathInterpolationTests {
    /// 直线与曲线配对时，线段控制点取前端点/后端点；双向半程得到同一个弧形轮廓。
    @Test func lineAndCubicMorphBothDirections() throws {
        let line = try SourcePath(verbs: [.move, .line, .close], points: [.zero, ScenePoint(x: 10, y: 0)])
        let curve = try SourcePath(verbs: [.move, .cubic, .close], points: [
            .zero, ScenePoint(x: 0, y: 10), ScenePoint(x: 10, y: 10), ScenePoint(x: 10, y: 0)])
        for (first, second) in [(line, curve), (curve, line)] {
            var budget = FramePlanBudget(limit: 10_000)
            let result = try PathInterpolation.interpolate(first, second, progress: 0.5, budget: &budget)
            #expect(result.verbs == [.move, .cubic, .close])
            #expect(result.points == [.zero, ScenePoint(x: 0, y: 5), ScenePoint(x: 10, y: 5), ScenePoint(x: 10, y: 0)])
            #expect(budget.used > 0)
        }
        // Bezier可产生overshoot，几何值层不把缓动比例擅自钳到0...1。
        var budget = FramePlanBudget(limit: 10_000)
        let beyond = try PathInterpolation.interpolate(line, curve, progress: 1.5, budget: &budget)
        #expect(beyond.points[1] == ScenePoint(x: 0, y: 15))
    }

    /// 常量、Hold和端点直接共享路径，不为每次采样复制点；单个零跨度在端点保持起值。
    @Test func endpointsHoldAndZeroSpanShareResources() throws {
        let first = try SourcePath(verbs: [.move], points: [.zero])
        let second = try SourcePath(verbs: [.move, .line], points: [.one, ScenePoint(x: 2, y: 2)])
        var budget = FramePlanBudget(limit: 1)
        #expect(try PropertyEvaluation.path(SourceProperty(constant: first), at: 50, budget: &budget) === first)
        let hold = try property(first, second, easing: .hold)
        for frame: Int64 in [-1, 0, 5, 9] {
            #expect(try PropertyEvaluation.path(hold, at: frame, budget: &budget) === first)
        }
        #expect(try PropertyEvaluation.path(hold, at: 10, budget: &budget) === second)
        let zero = try property(first, second, start: 5, end: 5)
        #expect(try PropertyEvaluation.path(zero, at: 5, budget: &budget) === first)
        #expect(try PropertyEvaluation.path(zero, at: 6, budget: &budget) === second)
        #expect(budget.used == 0)
    }

    /// 任一端为空时严格段内结果为空，时间端点仍共享真实非空路径，不补造点或淡入画面。
    @Test func emptyEndpointOnlyAffectsInterior() throws {
        let empty = try SourcePath(verbs: [], points: [])
        let nonempty = try SourcePath(verbs: [.move], points: [.one])
        for (first, second) in [(empty, nonempty), (nonempty, empty)] {
            let track = try property(first, second)
            var budget = FramePlanBudget(limit: 1_000)
            #expect(try PropertyEvaluation.path(track, at: 0, budget: &budget) === first)
            #expect(try PropertyEvaluation.path(track, at: 5, budget: &budget).verbs.isEmpty)
            #expect(try PropertyEvaluation.path(track, at: 10, budget: &budget) === second)
        }
    }

    /// 真实0.pag在6...12帧由曲线变直线，第9帧逐点核对独立Float位模式，乱序并发采样结果一致。
    @Test func realMorphHasIndependentMidpoint() async throws {
        let track = try PathFixtures.property(named: "0.pag", range: 631..<744)
        let expected: [[UInt32]] = [[0x42a0cccd, 0x42e7b333], [0x42a0cccd, 0x42e7b333],
            [0x42a32666, 0x42efa666], [0x42a32666, 0x42f13334], [0x42a32666, 0x42f2cccd],
            [0x42a0cccd, 0x42fa999a], [0x42a0cccd, 0x42fa999a]]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for frame: Int64 in [9, 12, 0, 25, 9, 6, 12, 9] {
                group.addTask {
                    var budget = FramePlanBudget(limit: 10_000)
                    let result = try PropertyEvaluation.path(track, at: frame, budget: &budget)
                    if frame == 9 {
                        #expect(result.verbs == [.move, .cubic, .cubic])
                        #expect(result.points.map { [Float($0.x).bitPattern, Float($0.y).bitPattern] } == expected)
                    } else if frame == 12 {
                        #expect(result.verbs == [.move, .line, .line])
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// 点数/非有限坐标和非空拓扑不匹配明确失败；曲线首段缺前点也不能靠数组负下标补线段。
    @Test func rejectsMalformedLayoutAndMorphTopology() throws {
        #expect(throws: SceneValidator.invalid("invalidPathPoints")) { try SourcePath(verbs: [.cubic], points: [.zero]) }
        #expect(throws: SceneValidator.invalid("invalidPathPoints")) { try SourcePath(verbs: [], points: [.zero]) }
        #expect(throws: SceneValidator.invalid("nonFinitePathPoint")) {
            try SourcePath(verbs: [.move], points: [ScenePoint(x: .nan, y: 0)])
        }
        let move = try SourcePath(verbs: [.move], points: [.zero])
        let close = try SourcePath(verbs: [.close], points: [])
        let line = try SourcePath(verbs: [.line], points: [.one])
        let curve = try SourcePath(verbs: [.cubic], points: [.zero, .one, .one])
        let longer = try SourcePath(verbs: [.move, .close], points: [.zero])
        for other in [close, line, longer] {
            #expect(throws: SceneValidator.invalid("incompatiblePathTopology")) { try move.validateInterpolation(to: other) }
        }
        #expect(throws: SceneValidator.invalid("incompatiblePathTopology")) { try line.validateInterpolation(to: curve) }
    }

    /// 插值预算在分配前拒绝，Float溢出保持错误；预先取消连常量路径也不能发布。
    @Test func budgetOverflowAndCancellation() async throws {
        let first = try SourcePath(verbs: [.move], points: [ScenePoint(x: 1e38, y: 0)])
        let second = try SourcePath(verbs: [.move], points: [ScenePoint(x: -1e38, y: 0)])
        var tiny = FramePlanBudget(limit: 127)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try PathInterpolation.interpolate(first, second, progress: 0.5, budget: &tiny)
        }
        var budget = FramePlanBudget(limit: 10_000)
        #expect(throws: SceneValidator.invalid("unrepresentablePropertyValue")) {
            try PathInterpolation.interpolate(first, second, progress: 3, budget: &budget)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var budget = FramePlanBudget(limit: 10_000)
            return try PropertyEvaluation.path(SourceProperty(constant: first), at: 0, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 构造纯语义轨道以隔离几何数值测试；这里不编码任何PAG字节。
    private func property(_ first: SourcePath, _ second: SourcePath, start: Int64 = 0, end: Int64 = 10,
                          easing: SourceEasing = .linear) throws -> SourceProperty<SourcePath> {
        try SourceProperty(keyframes: [SourceKeyframe(startFrame: start, endFrame: end,
            startValue: first, endValue: second, easing: easing, spatialCurve: nil)])
    }
}
