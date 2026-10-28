import Testing
@testable import pag_swift

/// 普通描边的纯值语义，包括源码回落、动画时钟及未被真实文件覆盖的枚举分支。
struct StrokeEvaluationTests {
    /// 透明或非正宽不产生paint，极小正宽保留hairline标志；阈值外不被钳到一像素。
    @Test func widthOpacityAndHairlineBoundaries() throws {
        for width in [-2.0, 0] {
            #expect(try StrokeEvaluation.evaluate(StrokeFixtures.make(width: .init(constant: width)), at: 0) == nil)
        }
        #expect(try StrokeEvaluation.evaluate(StrokeFixtures.make(opacity: .init(constant: 0)), at: 0) == nil)
        let boundary: Float = 1 / 4096
        for width in [boundary.nextDown, boundary, boundary.nextUp] {
            let value = try #require(try StrokeEvaluation.evaluate(StrokeFixtures.make(width: .init(constant: Double(width))), at: 0))
            #expect(value.style.isHairline == (width <= boundary))
            #expect(value.style.width == Double(width))
        }
    }

    /// 只有miter接角受到limit<=1影响；负limit恢复4，round不能因此变成bevel，square端点与Above顺序保持。
    @Test func miterNormalizationDoesNotChangeRoundJoins() throws {
        for join in [SourceLineJoin.miter, .round, .bevel] {
            for limit in [-2.0, 0, 1, 4] {
                let source = StrokeFixtures.make(miter: .init(constant: limit), cap: .square, join: join, order: .abovePrevious)
                let value = try #require(try StrokeEvaluation.evaluate(source, at: 0))
                #expect(value.style.join == (join == .miter && (0...1).contains(limit) ? .bevel : join))
                #expect(value.style.miterLimit == (limit < 0 ? 4 : limit))
                #expect(value.style.cap == .square && value.compositeOrder == .abovePrevious)
            }
        }
    }

    /// 奇数数组整体重复，负/整周期相位与每个合法零项都保留消费语义。
    @Test func dashDuplicationPhaseAndZeroIntervals() throws {
        let odd = try #require(try StrokeDashPattern.make(intervals: [2, 3, 5], phase: -3))
        #expect(odd.intervals == [2, 3, 5, 2, 3, 5] && odd.period == 20 && odd.phase == 17)
        for phase in [-40.0, -20, 0, 20, 40] {
            #expect(try StrokeDashPattern.make(intervals: [10], phase: phase)?.phase == 0)
        }
        let dots = try #require(try StrokeDashPattern.make(intervals: [0, 10], phase: 3))
        #expect(dots.intervals == [0, 10] && dots.phase == 3)
        #expect(try StrokeDashPattern.make(intervals: [10, 0], phase: -1)?.phase == 9)
        #expect(try StrokeDashPattern.make(intervals: Array(repeating: 1, count: 8), phase: 9)?.phase == 1)
        #expect(throws: SceneValidator.invalid("invalidStrokeDashCount")) {
            try SourceDashes(offset: .init(constant: 0), intervals: [])
        }
        #expect(throws: SceneValidator.invalid("invalidStrokeDashCount")) {
            try StrokeDashPattern.make(intervals: Array(repeating: 1, count: 9), phase: 0)
        }
    }

    /// 无效effect按源码继续实线，但非有限输入是本库严格错误；Float累加不能换成Double周期。
    @Test func invalidEffectsFallBackAndPeriodUsesFloat() throws {
        for intervals in [[], [0], [0, 0], [2, -1], [Double(Float.greatestFiniteMagnitude), Double(Float.greatestFiniteMagnitude)]] {
            #expect(try StrokeDashPattern.make(intervals: intervals, phase: 0) == nil)
        }
        let precise = try #require(try StrokeDashPattern.make(intervals: [16_777_216, 1, 1, 1], phase: 16_777_220))
        #expect(precise.period == 16_777_216 && precise.phase == 4)
        #expect(throws: SceneValidator.invalid("unrepresentablePropertyValue")) {
            try StrokeDashPattern.make(intervals: [.nan, 1], phase: 0)
        }
        #expect(throws: SceneValidator.invalid("unrepresentablePropertyValue")) {
            try StrokeDashPattern.make(intervals: [1, 1], phase: .infinity)
        }
    }

    /// 原始轨道全部按源合成帧采样，几何与颜色独立，虚线负值可由动画触发实线回落。
    @Test func animatedPropertiesUseOneSourceFrame() throws {
        let color = try StrokeFixtures.track(SceneColor(red: 0, green: 200, blue: 10), SceneColor(red: 101, green: 0, blue: 20))
        let dash = try SourceDashes(offset: StrokeFixtures.track(0.0, 10), intervals: [StrokeFixtures.track(2.0, -2), .init(constant: 10)])
        let source = StrokeFixtures.make(width: try StrokeFixtures.track(2.0, 6), miter: try StrokeFixtures.track(0.0, 4),
            color: color, opacity: try StrokeFixtures.track(UInt8(100), UInt8(200)), dashes: dash)
        let middle = try #require(try StrokeEvaluation.evaluate(source, at: 5))
        #expect(source.isAnimated && dash.isAnimated)
        #expect(middle.style.width == 4 && middle.style.miterLimit == 2 && middle.style.join == .miter)
        #expect(middle.color == SceneColor(red: 50, green: 100, blue: 15) && middle.opacity == 150.0 / 255)
        #expect(middle.style.dashes?.intervals == [0, 10] && middle.style.dashes?.phase == 5)
        #expect(try StrokeEvaluation.evaluate(source, at: 8)?.style.dashes == nil)
    }

    /// 每一种单独动画都使源Stroke依赖采样帧，常量源不被误判为动画。
    @Test func detectsEachAnimatedProperty() throws {
        let scalar = try StrokeFixtures.track(1.0, 2)
        let offset = try SourceDashes(offset: scalar, intervals: [.init(constant: 10)])
        let interval = try SourceDashes(offset: .init(constant: 0), intervals: [scalar])
        let variants = [StrokeFixtures.make(width: scalar), StrokeFixtures.make(miter: scalar),
            StrokeFixtures.make(color: try StrokeFixtures.track(.defaultFill, SceneColor(red: 0, green: 0, blue: 0))),
            StrokeFixtures.make(opacity: try StrokeFixtures.track(UInt8(1), UInt8(2))),
            StrokeFixtures.make(dashes: offset), StrokeFixtures.make(dashes: interval)]
        #expect(variants.allSatisfy(\.isAnimated) && !StrokeFixtures.make().isAnimated)
    }

    /// 颜色Hold与零跨度遵循共有端点规则，实际overshoot曲线逐通道钳位而不是UInt8环绕。
    @Test func colorHoldZeroSpanAndOvershoot() throws {
        let first = SceneColor(red: 10, green: 240, blue: 0), last = SceneColor(red: 240, green: 10, blue: 255)
        let hold = try StrokeFixtures.track(first, last, easing: .hold)
        #expect(try PropertyEvaluation.color(hold, at: 9) == first)
        #expect(try PropertyEvaluation.color(hold, at: 10) == last)
        let zero = try StrokeFixtures.track(first, last, start: 5, end: 5)
        #expect(try PropertyEvaluation.color(zero, at: 5) == first)
        #expect(try PropertyEvaluation.color(zero, at: 6) == last)
        let stroke = try StrokeFixtures.source(named: "PAG_LOGO.pag", range: 10252..<10312)
        let easing = try #require(stroke.width.keyframes.last).easing
        let track = try StrokeFixtures.track(first, last, easing: easing)
        #expect(try PropertyEvaluation.color(track, at: 5) == SceneColor(red: 255, green: 0, blue: 255))
    }

    /// 预取消连常量求值也失败，Float无法表示的正宽不能发布到绘制层。
    @Test func cancellationAndUnrepresentableValuesFail() async throws {
        #expect(throws: SceneValidator.invalid("unrepresentablePropertyValue")) {
            try StrokeEvaluation.evaluate(StrokeFixtures.make(width: .init(constant: Double.greatestFiniteMagnitude)), at: 0)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try StrokeEvaluation.evaluate(StrokeFixtures.make(), at: 0)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
