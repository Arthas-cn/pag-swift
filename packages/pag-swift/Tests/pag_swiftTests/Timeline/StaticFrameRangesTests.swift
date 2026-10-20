import Testing
@testable import pag_swift

/// 以源码独立区间金值验证静态时间内核；不把内部计算通过称为快照或绘制支持。
struct StaticFrameRangesTests {
    /// Linear/Bezier均扣除半开动画期，Hold保留分段；端点值相同不能消除动画。
    @Test func propertyModesUseSourceIntervals() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        let input = try StaticFrameRanges(startFrame: 0, duration: 100, budget: &budget)
        var curveBudget = DecodeBudget(limit: 1_000_000)
        let bezier = try SampledCurve.make(start: .zero, control1: .zero, control2: .one, end: .one,
                                          precision: 0.005, budget: &curveBudget)
        for easing in [SourceEasing.linear, .bezier(first: bezier, second: nil)] {
            let property = try Self.property(start: 20, end: 40, easing: easing)
            #expect(try input.excluding(property, budget: &budget).ranges == [0...19, 40...99])
        }
        let hold = try Self.property(start: 20, end: 40, easing: .hold)
        let split = try input.excluding(hold, budget: &budget)
        #expect(split.ranges == [0...19, 20...39, 40...99])
        #expect(try split.covers(startFrame: 0, duration: 100) == false)
        #expect(try input.covers(startFrame: 0, duration: 100))
        let all = try Self.property(start: 0, end: 100, easing: .linear)
        #expect(try input.excluding(all, budget: &budget).ranges.isEmpty)
    }

    /// 零跨度转为分割，轨道外的动画与常量不改变范围；不按isAnimated一刀切判静态。
    @Test func zeroDurationAndOutsideAnimation() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        let input = try StaticFrameRanges(startFrame: 0, duration: 100, budget: &budget)
        let zero = try Self.property(start: 20, end: 20, easing: .linear)
        #expect(try input.excluding(zero, budget: &budget).ranges == [0...19, 20...99])
        for easing in [SourceEasing.linear, .hold] {
            let outside = try Self.property(start: 120, end: 140, easing: easing)
            #expect(try input.excluding(outside, budget: &budget) == input)
        }
        #expect(try input.excluding(SourceProperty(constant: 8.0), budget: &budget) == input)
    }

    /// Split/Subtract只丢弃新生单帧；未命中或在原起点Split的既有单帧保留。
    @Test func singletonRulesDependOnOperation() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        let input = try StaticFrameRanges([0...9], budget: &budget)
        #expect(try input.splitting(at: 1, budget: &budget).ranges == [1...9])
        #expect(try input.splitting(at: 9, budget: &budget).ranges == [0...8])
        #expect(try input.subtracting(from: 1, through: 8, budget: &budget).ranges.isEmpty)
        #expect(try input.subtracting(from: 3, through: 2, budget: &budget).ranges == [0...2, 3...9])
        let single = try StaticFrameRanges([5...5], budget: &budget)
        #expect(try single.splitting(at: 5, budget: &budget) == single)
        #expect(try single.subtracting(from: 6, through: 9, budget: &budget) == single)
        #expect(try single.subtracting(from: 5, through: 5, budget: &budget).ranges.isEmpty)
    }

    /// 多个源区间与相交边界保持顺序、单帧和相邻片段；不合并不同静态段。
    @Test func intersectionKeepsPointAndAdjacentBoundaries() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        let left = try StaticFrameRanges([0...5, 6...10, 20...30], budget: &budget)
        let right = try StaticFrameRanges([5...8, 10...25], budget: &budget)
        let expected: [ClosedRange<Int64>] = [5...5, 6...8, 10...10, 20...25]
        #expect(try left.intersection(right, budget: &budget).ranges == expected)
        #expect(try right.intersection(left, budget: &budget).ranges == expected)
        #expect(try left.subtracting(from: 4, through: 22, budget: &budget).ranges == [0...3, 23...30])
        let empty = try StaticFrameRanges([], budget: &budget)
        #expect(try left.intersection(empty, budget: &budget) == empty)
    }

    /// 平移和二分折叠支持负时间、首末边界与空洞，完整判断必须恰好唯一完整片段。
    @Test func offsetAndRepresentativeFrames() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        let input = try StaticFrameRanges([0...19, 20...39, 50...99], budget: &budget)
        let shifted = try input.offsetting(by: -30, budget: &budget)
        #expect(shifted.ranges == [-30 ... -11, -10...9, 20...69])
        for (frame, expected) in [(-31, -31), (-30, -30), (-11, -30), (-10, -10), (9, -10),
                                  (10, 10), (20, 20), (69, 20), (70, 70)] {
            #expect(try shifted.representativeFrame(for: Int64(frame), budget: &budget) == Int64(expected))
        }
        #expect(try shifted.covers(startFrame: -30, duration: 100) == false)
    }

    /// 极端端点先做安全比较再±1；合法max末帧与min零跨度不因中间算术溢出失败。
    @Test func integerExtremesRemainDefined() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        let last = try StaticFrameRanges(startFrame: .max, duration: 1, budget: &budget)
        #expect(try last.covers(startFrame: .max, duration: 1))
        let first = try StaticFrameRanges(startFrame: .min, duration: 3, budget: &budget)
        let zero = try Self.property(start: .min, end: .min, easing: .linear)
        #expect(try first.excluding(zero, budget: &budget) == first)
        #expect(try first.subtracting(from: .min, through: .min, budget: &budget).ranges == [(.min + 1)...(.min + 2)])
        let all = try StaticFrameRanges([Int64.min...Int64.max], budget: &budget)
        #expect(try all.subtracting(from: .min, through: .max, budget: &budget).ranges.isEmpty)
        #expect(try all.splitting(at: .max, budget: &budget).ranges == [Int64.min...(Int64.max - 1)])
        #expect(throws: PAGError.self) { try last.offsetting(by: 1, budget: &budget) }
        #expect(throws: PAGError.self) { try first.offsetting(by: -1, budget: &budget) }
        #expect(last.ranges == [Int64.max...Int64.max])
    }

    /// 非正时长、终点溢出、乱序与重叠都拒绝；相邻区间及合法单帧允许构造。
    @Test func invalidInputsFailBeforePublishing() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        for duration: Int64 in [0, -1, .min] {
            #expect(throws: PAGError.self) { try StaticFrameRanges(startFrame: 0, duration: duration, budget: &budget) }
        }
        #expect(throws: PAGError.self) { try StaticFrameRanges(startFrame: .max, duration: 2, budget: &budget) }
        for ranges: [ClosedRange<Int64>] in [[0...5, 5...9], [6...9, 0...5]] {
            #expect(throws: PAGError.self) { try StaticFrameRanges(ranges, budget: &budget) }
        }
        #expect(try StaticFrameRanges([0...0, 1...1], budget: &budget).ranges.count == 2)
    }

    /// 一个输入访问和两个输出需要96逻辑字节；差一字节失败后原集合仍完整可复用。
    @Test func exactBudgetFailureKeepsOriginal() throws {
        var setup = FramePlanBudget(limit: 1_000_000)
        let input = try StaticFrameRanges([0...99], budget: &setup)
        var tiny = FramePlanBudget(limit: 95)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try input.splitting(at: 20, budget: &tiny)
        }
        #expect(input.ranges == [0...99])
        var exact = FramePlanBudget(limit: 96)
        #expect(try input.splitting(at: 20, budget: &exact).ranges == [0...19, 20...99])
        #expect(exact.used == 96)
        // Hold两次转换的输出都收费，不能只按最终三个片段计算留存。
        let hold = try Self.property(start: 20, end: 40, easing: .hold)
        var cumulative = FramePlanBudget(limit: 288)
        #expect(try input.excluding(hold, budget: &cumulative).ranges == [0...19, 20...39, 40...99])
        #expect(cumulative.used == 288)
    }

    /// 共享不可变输入可并发乱序求值；预取消包括空输入也必须失败，不返回成功空结果。
    @Test func concurrencyAndPreCancellation() async throws {
        var setup = FramePlanBudget(limit: 1_000_000)
        let input = try StaticFrameRanges([0...99], budget: &setup)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in (2...30).reversed() {
                group.addTask {
                    var budget = FramePlanBudget(limit: 1_000_000)
                    let split = try input.splitting(at: Int64(index), budget: &budget)
                    #expect(split.ranges == [0...Int64(index - 1), Int64(index)...99])
                }
            }
            try await group.waitForAll()
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var budget = FramePlanBudget(limit: 1_000_000)
            return try StaticFrameRanges([], budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(input.ranges == [0...99])
    }

    /// 空集合的每个入口仍响应预取消；不能因为没有循环迭代而返回成功空值。
    @Test(arguments: 0..<8)
    func emptyOperationsObserveCancellation(operation: Int) async throws {
        var setup = FramePlanBudget(limit: 1_000_000)
        let empty = try StaticFrameRanges([], budget: &setup)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var budget = FramePlanBudget(limit: 1_000_000)
            switch operation {
            case 0: _ = try empty.splitting(at: 0, budget: &budget)
            case 1: _ = try empty.subtracting(from: 0, through: 1, budget: &budget)
            case 2: _ = try empty.intersection(empty, budget: &budget)
            case 3: _ = try empty.offsetting(by: 1, budget: &budget)
            case 4: _ = try empty.excluding(SourceProperty(constant: 1.0), budget: &budget)
            case 5: _ = try empty.covers(startFrame: 0, duration: 1)
            case 6: _ = try empty.representativeFrame(for: 0, budget: &budget)
            default: _ = try empty.relative(to: 0, budget: &budget)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 穷举小整数扣除区间，用逐帧集合再分段的独立参照核对全部包含与相交分支。
    @Test func subtractionMatchesIndependentDiscreteReference() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        let input = try StaticFrameRanges([0...9], budget: &budget)
        for start in -2...12 {
            for end in start...12 {
                let remaining = (0...9).filter { $0 < start || $0 > end }
                var groups: [[Int]] = []
                for frame in remaining {
                    if let last = groups.last?.last, last + 1 == frame {
                        groups[groups.count - 1].append(frame)
                    } else {
                        groups.append([frame])
                    }
                }
                // 参照以离散帧重新分组，不复用生产端点截断算法；新生单帧不算静态段。
                let expected = groups.filter { $0.count > 1 }.map { Int64($0[0])...Int64($0[$0.count - 1]) }
                #expect(try input.subtracting(from: Int64(start), through: Int64(end), budget: &budget).ranges == expected)
            }
        }
    }

    /// 相对最小原点的合法差值可表示；不合法差值溢出或预算不足不修改原集合。
    @Test func relativeOriginUsesCheckedSubtraction() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        let input = try StaticFrameRanges([Int64.min...(Int64.min + 99)], budget: &budget)
        #expect(try input.relative(to: .min, budget: &budget).ranges == [0...99])
        #expect(throws: PAGError.self) { try input.relative(to: 1, budget: &budget) }
        var tiny = FramePlanBudget(limit: 63)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try input.relative(to: .min, budget: &tiny)
        }
        #expect(input.ranges == [Int64.min...(Int64.min + 99)])
    }

    /// 生成两端数值相同的显式轨道，确保测试依赖时间语义而不是数值差异。
    private static func property(start: Int64, end: Int64, easing: SourceEasing) throws -> SourceProperty<Double> {
        try SourceProperty(keyframes: [SourceKeyframe(startFrame: start, endFrame: end,
            startValue: 5, endValue: 5, easing: easing, spatialCurve: nil)])
    }
}
