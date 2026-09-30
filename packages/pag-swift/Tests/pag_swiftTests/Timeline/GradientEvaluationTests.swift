import Testing
@testable import pag_swift

/// 渐变源帧求值与颜色程序候选复用；尚不代表形状缓存或Metal显示已接通。
struct GradientEvaluationTests {
    /// 单时间Bezier的overshoot同时作用于RGB和alpha，字节夹值而位置/中点不随时间改变。
    @Test func bezierOvershootClampsChannelsOnly() throws {
        var decodeBudget = DecodeBudget(limit: 1_000_000)
        let curve = try SampledCurve.make(start: .zero, control1: ScenePoint(x: 1.0 / 3, y: 2),
            control2: ScenePoint(x: 2.0 / 3, y: 2), end: .one, precision: 0.005, budget: &decodeBudget)
        let first = GradientColorFixtures.colors(rgb: [(0, GradientColorFixtures.red)], alpha: [(0, 0)])
        let last = GradientColorFixtures.colors(rgb: [(1, GradientColorFixtures.blue)], alpha: [(1, 255)])
        let property = try ShapePropertyFixtures.track(first, last, easing: .bezier(first: curve, second: nil))
        var budget = FramePlanBudget(limit: 1_000_000)
        let value = try GradientEvaluation.colors(property, at: 5, budget: &budget)
        #expect(value.colorStops[0].color == GradientColorFixtures.blue && value.alphaStops[0].opacity == 255)
        #expect(value.colorStops[0].position == 0 && value.alphaStops[0].position == 0)
    }

    /// 不同调用并发乱序求值同源轨道，各自预算独立，结果不依赖其他调用的历史游标。
    @Test func concurrentSamplingHasNoSharedCursor() async throws {
        let first = GradientColorFixtures.colors(alpha: [(0, 0), (1, 0)])
        let last = GradientColorFixtures.colors(alpha: [(0, 255), (1, 255)])
        let property = try ShapePropertyFixtures.track(first, last)
        try await withThrowingTaskGroup(of: (Int64, UInt8).self) { group in
            for frame in (Int64(0)...10).reversed() {
                group.addTask {
                    var budget = FramePlanBudget(limit: 1_000_000)
                    let value = try GradientEvaluation.colors(property, at: frame, budget: &budget)
                    return (frame, value.alphaStops[0].opacity)
                }
            }
            for try await (frame, opacity) in group { #expect(opacity == UInt8(Float(frame) / 10 * 255)) }
        }
    }

    /// 常量、Hold、区间外和端点共用原对象且不分配颜色表；零跨度端点遵循现有源时间规则。
    @Test func endpointsHoldAndZeroSpanKeepSourceIdentity() throws {
        let first = GradientColorFixtures.colors()
        let last = GradientColorFixtures.colors(rgb: [(0, .defaultFill)], alpha: [(0, 42)])
        let hold = try ShapePropertyFixtures.track(first, last, easing: .hold)
        var budget = FramePlanBudget(limit: 1)
        #expect(try GradientEvaluation.colors(.init(constant: first), at: 50, budget: &budget) === first)
        #expect(try GradientEvaluation.colors(hold, at: -1, budget: &budget) === first)
        #expect(try GradientEvaluation.colors(hold, at: 5, budget: &budget) === first)
        #expect(try GradientEvaluation.colors(hold, at: 10, budget: &budget) === last)
        let zero = try SourceProperty(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 0,
            startValue: first, endValue: last, easing: .linear, spatialCurve: nil)])
        #expect(try GradientEvaluation.colors(zero, at: 0, budget: &budget) === first)
        #expect(try GradientEvaluation.colors(zero, at: 1, budget: &budget) === last)
        #expect(budget.used == 0)
    }

    /// 中段保留start所有位置/中点及尾项，只改变两端共有前缀；末帧采用end完整不同长度表。
    @Test func interpolationKeepsStartLayoutAndQuantizesBytes() throws {
        let first = GradientColorFixtures.colors(rgb: [(0, GradientColorFixtures.red), (1, GradientColorFixtures.blue)],
            alpha: [(0, 0), (0.5, 200), (1, 42)], colorMidpoint: 0.25, alphaMidpoint: 1)
        let last = GradientColorFixtures.colors(rgb: [(0.2, GradientColorFixtures.blue)],
            alpha: [(0.1, 255), (1, 1)], colorMidpoint: 0.75, alphaMidpoint: 0)
        let property = try ShapePropertyFixtures.track(first, last)
        var budget = FramePlanBudget(limit: 1_000_000)
        let middle = try GradientEvaluation.colors(property, at: 5, budget: &budget)
        #expect(middle !== first && middle !== last)
        #expect(middle.alphaStops.map(\.opacity) == [127, 100, 42])
        #expect(middle.alphaStops.map(\.position) == [0, 0.5, 1])
        #expect(middle.alphaStops.map(\.midpoint) == [1, 1, 1])
        #expect(middle.colorStops.map(\.color) == [SceneColor(red: 127, green: 0, blue: 127), GradientColorFixtures.blue])
        #expect(middle.colorStops.map(\.position) == [0, 1] && middle.colorStops.map(\.midpoint) == [0.25, 0.25])
        #expect(try GradientEvaluation.colors(property, at: 10, budget: &budget) === last)
    }

    /// 真正颜色插值创建新身份，同一原对象在端点/opacity动画下复用完整已编译程序。
    @Test func candidatesReuseOnlyIdenticalSourceColors() throws {
        let colors = GradientColorFixtures.colors()
        let source = try SourceGradient(kind: .radial, start: ShapePropertyFixtures.track(.zero, ScenePoint(x: 10, y: 20)),
            end: .init(constant: ScenePoint(x: 100, y: 0)), colors: .init(constant: colors),
            opacity: ShapePropertyFixtures.track(UInt8(0), UInt8(255)))
        var budget = FramePlanBudget(limit: 1_000_000)
        let first = try GradientEvaluation.prepare(source, at: 0, matrix: .identity, reusing: [], budget: &budget)
        let middle = try GradientEvaluation.prepare(source, at: 5, matrix: .identity, reusing: [first.colorizer], budget: &budget)
        #expect(first.colorizer === middle.colorizer && middle.start == ScenePoint(x: 5, y: 10))
        let sameValues = GradientColorFixtures.source(.init(constant: GradientColorFixtures.colors()))
        let different = try GradientEvaluation.prepare(sameValues, at: 0, matrix: .identity, reusing: [first.colorizer], budget: &budget)
        #expect(different.colorizer !== first.colorizer)
        let animated = try GradientColorFixtures.source(ShapePropertyFixtures.track(colors, colors))
        let interpolated = try GradientEvaluation.prepare(animated, at: 5, matrix: .identity, reusing: [first.colorizer], budget: &budget)
        #expect(interpolated.colorizer !== first.colorizer && interpolated.colorizer.source !== colors)
    }

    /// 命中预算仅包含材料/程序保活与有限身份检查，不重新展开4096项源表；失败保留先前程序。
    @Test func warmProgramChargesRetentionWithoutStopWork() throws {
        let colors = GradientColorFixtures.colors(rgb: (0..<4096).map { (Float($0) / 4095, GradientColorFixtures.red) })
        let source = GradientColorFixtures.source(.init(constant: colors))
        var coldBudget = FramePlanBudget(limit: 64 * 1024 * 1024)
        let cold = try GradientEvaluation.prepare(source, at: 0, matrix: .identity, reusing: [], budget: &coldBudget)
        let warmCost = cold.estimatedBytes + 16
        var warmBudget = FramePlanBudget(limit: warmCost)
        let warm = try GradientEvaluation.prepare(source, at: 1, matrix: .identity, reusing: [cold.colorizer], budget: &warmBudget)
        #expect(warm.colorizer === cold.colorizer && warmBudget.used == warmCost && coldBudget.used > warmBudget.used)
        var limited = FramePlanBudget(limit: warmCost - 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try GradientEvaluation.prepare(source, at: 2, matrix: .identity, reusing: [cold.colorizer], budget: &limited)
        }
        #expect(cold.colorizer.source === colors)
    }

    /// 颜色插值的完整预算刚好成功，少一个逻辑字节失败；预取消在常量和材料准备入口同样有效。
    @Test func budgetsAndCancellationFailAtomically() async throws {
        let first = GradientColorFixtures.colors()
        let property = try ShapePropertyFixtures.track(first, first)
        var budget = FramePlanBudget(limit: 1_000_000)
        _ = try GradientEvaluation.colors(property, at: 5, budget: &budget)
        var limited = FramePlanBudget(limit: budget.used - 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try GradientEvaluation.colors(property, at: 5, budget: &limited)
        }
        var exact = FramePlanBudget(limit: budget.used)
        #expect(try GradientEvaluation.colors(property, at: 5, budget: &exact) !== first)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.cancelAll()
            group.addTask {
                var cancelled = FramePlanBudget(limit: 1_000_000)
                #expect(throws: CancellationError.self) { try GradientEvaluation.colors(property, at: 5, budget: &cancelled) }
                #expect(throws: CancellationError.self) {
                    try GradientEvaluation.prepare(GradientColorFixtures.source(.init(constant: first)), at: 0,
                                                   matrix: .identity, reusing: [], budget: &cancelled)
                }
                #expect(cancelled.used == 0)
            }
            for try await _ in group {}
        }
    }
}
