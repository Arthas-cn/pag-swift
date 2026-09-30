import Testing
@testable import pag_swift

/// 轨道端点、Hold、缓动和空间采样；语义片段不冒充完整 PAG 格式夹具。
struct PropertyEvaluationTests {
    /// 常量及首末区间外的值保持稳定；负帧和 Int64 极值不会参与溢出减法。
    @Test func constantAndOutsideFramesHoldTheirValues() throws {
        let constant = SourceProperty(constant: 12.0)
        #expect(try PropertyEvaluation.scalar(constant, at: .min) == 12)
        let track = try SourceProperty(keyframes: [keyframe(-10, 10, 20.0, 40.0, .linear)])
        for frame in [Int64.min, -11, -10] { #expect(try PropertyEvaluation.scalar(track, at: frame) == 20) }
        for frame in [Int64.max, 11, 10] { #expect(try PropertyEvaluation.scalar(track, at: frame) == 40) }
        #expect(try PropertyEvaluation.scalar(track, at: 0) == 30)
    }

    /// Hold 的右端必须切换下一段，最后一个 Hold 在自身终点后保持最终 endValue。
    @Test func holdUsesRightOpenIntervals() throws {
        let track = try SourceProperty(keyframes: [keyframe(-10, 0, 10.0, 30.0, .hold),
                                                   keyframe(0, 10, 30.0, 90.0, .hold)])
        #expect(try PropertyEvaluation.scalar(track, at: -1) == 10)
        #expect(try PropertyEvaluation.scalar(track, at: 0) == 30)
        #expect(try PropertyEvaluation.scalar(track, at: 9) == 30)
        #expect(try PropertyEvaluation.scalar(track, at: 10) == 90)
    }

    /// 多维属性的两条时间曲线分别生效，不能只求 x 后复用于 y。
    @Test func pointComponentsUseIndependentTimingCurves() throws {
        let first = try curve(.zero, ScenePoint(x: 1.0 / 3, y: 0), ScenePoint(x: 2.0 / 3, y: 1.0 / 3), .one)
        let second = try curve(.zero, ScenePoint(x: 1.0 / 3, y: 2.0 / 3), ScenePoint(x: 2.0 / 3, y: 1), .one)
        let track = try SourceProperty(keyframes: [keyframe(0, 100, ScenePoint.zero, ScenePoint(x: 100, y: 100),
                                                            .bezier(first: first, second: second))])
        let value = try PropertyEvaluation.point(track, at: 50)
        #expect(abs(value.x - 25) < 0.5)
        #expect(abs(value.y - 75) < 0.5)
    }

    /// 缓动 y 可超过 1；标量保留 overshoot，UInt8 则在截断前钳位。
    @Test func opacityClampsOvershootAndTruncatesFraction() throws {
        let easing = try curve(.zero, ScenePoint(x: 1.0 / 3, y: 2), ScenePoint(x: 2.0 / 3, y: 2), .one)
        let scalar = try SourceProperty(keyframes: [keyframe(0, 10, 0.0, 100.0, .bezier(first: easing, second: nil))])
        let opacity = try SourceProperty(keyframes: [keyframe(0, 10, UInt8(0), 255, .bezier(first: easing, second: nil))])
        #expect(try PropertyEvaluation.scalar(scalar, at: 5) > 100)
        #expect(try PropertyEvaluation.opacity(opacity, at: 5) == 255)
        let linear = try SourceProperty(keyframes: [keyframe(0, 2, UInt8(0), 255, .linear)])
        #expect(try PropertyEvaluation.opacity(linear, at: 1) == 127)
    }

    /// 空列表、倒序、间隙和跨度溢出都必须在创建轨道时拒绝。
    @Test func invalidTrackTopologyFails() throws {
        #expect(throws: SceneValidator.invalid("emptyKeyframes")) { try SourceProperty<Double>(keyframes: []) }
        let invalid = [
            [keyframe(1, 0, 0.0, 1.0, .linear)],
            [keyframe(Int64.min, Int64.max, 0.0, 1.0, .linear)],
            [keyframe(0, 1, 0.0, 1.0, .linear), keyframe(2, 3, 1.0, 2.0, .linear)]
        ]
        for frames in invalid {
            #expect(throws: SceneValidator.invalid("invalidKeyframeTimes")) { try SourceProperty(keyframes: frames) }
        }
    }

    /// 同一不可变轨道可并发乱序求值，不受另一调用的上次关键帧位置影响。
    @Test func concurrentRandomAccessHasNoSharedCursor() async throws {
        let track = try SourceProperty(keyframes: [keyframe(0, 10, 0.0, 10.0, .linear),
                                                   keyframe(10, 20, 10.0, 20.0, .linear)])
        try await withThrowingTaskGroup(of: (Int64, Double).self) { group in
            for frame in (Int64(0)...20).reversed() {
                group.addTask { (frame, try PropertyEvaluation.scalar(track, at: frame)) }
            }
            for try await (frame, value) in group { #expect(value == Double(frame)) }
        }
    }

    /// 建立直接语义关键帧；故意不验证，供 SourceProperty 的入口校验测试使用。
    private func keyframe<Value: Sendable>(_ start: Int64, _ end: Int64, _ a: Value, _ b: Value,
                                            _ easing: SourceEasing) -> SourceKeyframe<Value> {
        SourceKeyframe(startFrame: start, endFrame: end, startValue: a, endValue: b, easing: easing, spatialCurve: nil)
    }

    /// 建立单条测试曲线，预算独立于其他并行用例。
    private func curve(_ a: ScenePoint, _ b: ScenePoint, _ c: ScenePoint, _ d: ScenePoint) throws -> SampledCurve {
        var budget = DecodeBudget(limit: 1_000_000)
        return try SampledCurve.make(start: a, control1: b, control2: c, end: d, precision: 0.005, budget: &budget)
    }
}
