import Foundation
import Testing
@testable import pag_swift

/// Trim的Float参数选择与时间求值；独立预期区间来自源分支，不涉及测量或绘制。
struct TrimEvaluationTests {
    /// 完整、反向、多圈、正负余数和缺省100保留源码分支，不能统一clamp或任意取模。
    @Test func selectionsPreserveSourceOrder() throws {
        #expect(try select(0, 1) == .unchanged(reversed: false))
        #expect(try select(1, 0) == .unchanged(reversed: true))
        #expect(try select(0, 1, offset: 1080) == .unchanged(reversed: false))
        #expect(try select(0, 1, offset: -90) == ranges(0.75, 1, second: TrimInterval(start: 0, end: 0.75)))
        #expect(try select(0, 100) == ranges(0, 1, second: TrimInterval(start: 0, end: 99)))
        #expect(try select(4, 5) == ranges(3, 1, second: TrimInterval(start: 0, end: 3)))
        #expect(try select(-5, -4) == ranges(-3, 1, second: TrimInterval(start: 0, end: -3)))
        #expect(try select(0.75, 0.25) == ranges(0.25, 0.75, reversed: true))
        #expect(try select(0.25, 0.75, mode: .individually)
                == .ranges(mode: .individually, reversed: false, first: TrimInterval(start: 0.25, end: 0.75), second: nil))
    }

    /// 近等比较是严格小于Float epsilon，发生在反向和移动一圈之前。
    @Test func equalAndAdjacentThresholdsRemainDistinct() throws {
        #expect(try select(1, 1) == .empty)
        #expect(try select(0, Float.ulpOfOne.nextDown) == .empty)
        #expect(try select(0, Float.ulpOfOne) == ranges(0, Float.ulpOfOne))
        #expect(try select(1, Float(1).nextDown) == .empty)
        #expect(try select(1, Float(1).nextUp) == ranges(1, 1, second: TrimInterval(start: 0, end: Float.ulpOfOne)))
        #expect(TrimInterval(start: 0, end: 1) != TrimInterval(start: -Float.zero, end: 1))
    }

    /// 三条轨道分别参与采样，端点/Hold/零跨度沿用共同属性规则，乱序seek无共享游标。
    @Test func allTracksUseSourceFrameAndEndpointRules() throws {
        let increasing = try SourceProperty(keyframes: [SourceKeyframe<Double>(startFrame: 0, endFrame: 10,
            startValue: 0, endValue: 1, easing: .linear, spatialCurve: nil)])
        let source = SourceTrimPaths(start: increasing, end: .init(constant: 1), offset: .init(constant: 0), mode: .simultaneously)
        for (frame, expected): (Int64, TrimSelection) in [(10, .empty), (5, ranges(0.5, 1)), (0, .unchanged(reversed: false))] {
            #expect(try TrimEvaluation.selection(source, at: frame) == expected)
        }
        let end = SourceTrimPaths(start: .init(constant: 0), end: increasing, offset: .init(constant: 0), mode: .simultaneously)
        #expect(try TrimEvaluation.selection(end, at: 5) == ranges(0, 0.5))
        let angle = try SourceProperty(keyframes: [SourceKeyframe<Double>(startFrame: 0, endFrame: 10,
            startValue: 0, endValue: 360, easing: .linear, spatialCurve: nil)])
        let offset = SourceTrimPaths(start: .init(constant: 0), end: .init(constant: 1), offset: angle, mode: .simultaneously)
        #expect(try TrimEvaluation.selection(offset, at: 5) == ranges(0.5, 1, second: TrimInterval(start: 0, end: 0.5)))
        #expect(try TrimEvaluation.selection(offset, at: 10) == .unchanged(reversed: false))
        let held = try SourceProperty(keyframes: [SourceKeyframe<Double>(startFrame: 0, endFrame: 10,
            startValue: 0.25, endValue: 0.75, easing: .hold, spatialCurve: nil),
            SourceKeyframe(startFrame: 10, endFrame: 10, startValue: 0.75, endValue: 1, easing: .linear, spatialCurve: nil)])
        let hold = SourceTrimPaths(start: held, end: .init(constant: 1), offset: .init(constant: 0), mode: .simultaneously)
        #expect(try TrimEvaluation.selection(hold, at: 9) == ranges(0.25, 1))
        // 共同规则先判frame<=start：尾部零跨度在唯一端点取startValue，越过后才取endValue。
        #expect(try TrimEvaluation.selection(hold, at: 10) == ranges(0.75, 1))
        #expect(try TrimEvaluation.selection(hold, at: 11) == .empty)
    }

    /// 新选择算术与已有属性插值错误保持分层，预取消不能返回即便是常量选择。
    @Test func precisionAndCancellationRemainExplicit() async throws {
        #expect(throws: PAGError.renderingFailure("trimPrecision")) {
            try select(-Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        }
        let property = try SourceProperty(keyframes: [SourceKeyframe<Double>(startFrame: 0, endFrame: 10,
            startValue: -Double(Float.greatestFiniteMagnitude), endValue: Double(Float.greatestFiniteMagnitude),
            easing: .linear, spatialCurve: nil)])
        let source = SourceTrimPaths(start: property, end: .init(constant: 1), offset: .init(constant: 0), mode: .simultaneously)
        #expect(throws: PAGError.invalidFile(reason: "unrepresentablePropertyValue", offset: nil)) {
            try TrimEvaluation.selection(source, at: 5)
        }
        await #expect(throws: CancellationError.self) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.cancelAll()
                group.addTask { _ = try select(0, 1) }
                for try await _ in group {}
            }
        }
    }

    /// 从纯语义常量构造选择；与PAG字节编码独立，Float值提升后再交消费者。
    private func select(_ start: Float, _ end: Float, offset: Float = 0,
                        mode: SourceTrimMode = .simultaneously) throws -> TrimSelection {
        try TrimEvaluation.selection(SourceTrimPaths(start: .init(constant: Double(start)), end: .init(constant: Double(end)),
            offset: .init(constant: Double(offset)), mode: mode), at: 0)
    }

    /// 构造独立预期的逐路径区间，不调用待测归一化算法。
    private func ranges(_ start: Float, _ end: Float, reversed: Bool = false,
                        second: TrimInterval? = nil) -> TrimSelection {
        .ranges(mode: .simultaneously, reversed: reversed, first: TrimInterval(start: start, end: end), second: second)
    }
}
