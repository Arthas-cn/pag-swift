import Testing
@testable import pag_swift

/// 根实例素材时间的源码算术与确定性边界，不使用MP4或系统时钟代替映射验证。
struct ImageTimeMappingTests {
    /// 无规则和常量规则都按可见起点归零，外侧走根时间，不把常量123当冻结素材帧。
    @Test func defaultAndConstantUseNormalizedLinearClock() throws {
        let constant = SourceImageFillRule(scaleMode: .aspectFit, timeRemap: SourceProperty(constant: 123))
        for rule in [nil, constant] {
            let layer = ImageTimeFixtures.layer(start: 5, rule: rule)
            let map = try ImageTimeFixtures.mapping(layer, visible: 5...15)
            for (frame, expected): (Int64, Int64) in [(4, 4), (5, 0), (10, 5), (15, 10), (16, 16)] {
                #expect(try map.time(at: frame, frameRate: 1).microseconds == expected * 1_000_000)
            }
        }
    }

    /// 正向、倒向与Hold均先扣最小端值；末端保持而不是把倒向轨道翻转成正向。
    @Test func linearReverseAndHoldKeepSourceEndpoints() throws {
        for (a, b, easing, values) in [(Int64(10), Int64(30), SourceEasing.linear, [0, 10, 20]),
                                      (30, 10, .linear, [20, 10, 0]), (10, 30, .hold, [0, 0, 20])] {
            let rule = try ImageTimeFixtures.rule([ImageTimeFixtures.key(2, 12, a, b, easing)])
            let map = try ImageTimeFixtures.mapping(ImageTimeFixtures.layer(start: 2, rule: rule), visible: 2...12, fileDuration: 13)
            for (frame, expected) in zip([Int64(2), 7, 12], values) {
                #expect(try map.time(at: frame, frameRate: 1).microseconds == Int64(expected) * 1_000_000)
            }
        }
    }

    /// 先右裁再左裁并扣最小端值；Hold直接取起值，切在其原终点也不能错误地取终值。
    @Test func clipsBothSidesAndHoldEndpoint() throws {
        let linear = try ImageTimeFixtures.rule([ImageTimeFixtures.key(-5, 15, 0, 100)])
        let map = try ImageTimeFixtures.mapping(ImageTimeFixtures.layer(rule: linear), visible: 0...10, fileDuration: 11)
        #expect(map.segments.count == 1 && map.segments[0].start == 0 && map.segments[0].end == 10)
        #expect(map.segments[0].first == 0 && map.segments[0].last == 50)
        #expect(try map.time(at: 5, frameRate: 1).microseconds == 25_000_000)
        let hold = try ImageTimeFixtures.rule([ImageTimeFixtures.key(-5, 0, 100, 200, .hold)])
        let held = try ImageTimeFixtures.mapping(ImageTimeFixtures.layer(rule: hold), visible: 0...10, fileDuration: 11)
        // 左裁只改起点，原终值200保留；归零后零段为0→100，后补尾段从100开始。
        #expect(held.segments[0].start == 0 && held.segments[0].end == 0)
        #expect(held.segments[0].first == 0 && held.segments[0].last == 100)
        #expect(try held.time(at: 0, frameRate: 1).microseconds == 100_000_000)
    }

    /// x=t/y=t²曲线裁剪后仍使用原interpolator：中间值约5而非重新截取原曲线得到的11。
    @Test func bezierCutKeepsInitializedInterpolator() throws {
        var budget = DecodeBudget(limit: 1_000_000)
        let curve = try SampledCurve.make(start: .zero, control1: ScenePoint(x: 1.0 / 3, y: 0),
            control2: ScenePoint(x: 2.0 / 3, y: 1.0 / 3), end: .one, precision: 0.005, budget: &budget)
        let rule = try ImageTimeFixtures.rule([ImageTimeFixtures.key(-10, 10, 0, 100, .bezier(first: curve, second: nil))])
        let map = try ImageTimeFixtures.mapping(ImageTimeFixtures.layer(duration: 6, rule: rule), visible: 0...5, fileDuration: 6)
        #expect(abs(map.segments[0].last - 31.25) < 0.15)
        #expect(abs(try map.time(at: 2, frameRate: 1).microseconds - 5_000_000) < 150_000)
    }

    /// Bezier可越过归零后的端值范围，负素材微秒保留给媒体采样层，不改根帧或擅自钳到零。
    @Test func bezierOvershootPreservesSignedContentTime() throws {
        var budget = DecodeBudget(limit: 1_000_000)
        let curve = try SampledCurve.make(start: .zero, control1: ScenePoint(x: 1.0 / 3, y: -1),
            control2: ScenePoint(x: 2.0 / 3, y: -1), end: .one, precision: 0.005, budget: &budget)
        let rule = try ImageTimeFixtures.rule([ImageTimeFixtures.key(0, 10, 0, 10, .bezier(first: curve, second: nil))])
        let map = try ImageTimeFixtures.mapping(ImageTimeFixtures.layer(rule: rule), visible: 0...10, fileDuration: 11)
        let time = try map.time(at: 5, frameRate: 1)
        #expect(abs(time.microseconds + 6_250_000) < 50_000)
        #expect(try map.time(at: 10, frameRate: 1).microseconds == 10_000_000)
    }

    /// CreateKeyframe在2²⁴以上先量化原始起止，再减原层起点；不能假设默认相对区间一定是0...8。
    @Test func generatedTimesRoundBeforeRemovingLayerStart() throws {
        let map = try ImageTimeFixtures.mapping(ImageTimeFixtures.layer(start: 16_777_217, duration: 9),
                                               visible: 0...8, fileDuration: 9)
        let first = try #require(map.segments.first)
        // Float起止为16777216/16777224，减真实start得到-1...7，再左裁到0。
        #expect(first.start == 0 && first.end == 7)
        #expect(first.first == 0 && first.last == 8)
        #expect(try map.time(at: 4, frameRate: 1).microseconds == 4_571_429)
    }

    /// 头补段终点向上量化后大于后续零段，累计终点索引仍选第一条end大于请求的段。
    @Test func roundedHeadWithUnsortedEndsKeepsFirstMatchingSegment() async throws {
        let point: Int64 = 16_777_219
        let rule = try ImageTimeFixtures.rule([ImageTimeFixtures.key(point, point, 1, 5)])
        let map = try ImageTimeFixtures.mapping(ImageTimeFixtures.layer(duration: 33_554_431, rule: rule),
                                               visible: 0...33_554_430, fileDuration: 33_554_431)
        #expect(map.segments.map(\.end) == [point + 1, point, 33_554_430])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for frame in [point, point + 1, point - 1, point + 1, point] {
                group.addTask {
                    let time = try map.time(at: frame, frameRate: 1)
                    #expect(time.microseconds == (frame <= point ? 0 : 4_000_000))
                }
            }
            try await group.waitForAll()
        }
    }

    /// 闭区间缩放保留重叠、空段与间隙；固定选段在并发倒序查询中不受上次游标影响。
    @Test func closedRangeRoundingIsDeterministic() async throws {
        let large = try ImageTimeFixtures.rule([ImageTimeFixtures.key(0, 5, 0, 5, .hold), ImageTimeFixtures.key(5, 10, 5, 10, .hold)])
        let expanded = try ImageTimeFixtures.mapping(ImageTimeFixtures.layer(rule: large), visible: 0...21, fileDuration: 22)
        #expect(expanded.segments.map(\.start) == [0, 10] && expanded.segments.map(\.end) == [11, 21])
        let small = try ImageTimeFixtures.rule([ImageTimeFixtures.key(0, 2, 0, 10, .hold),
            ImageTimeFixtures.key(2, 2, 10, 20, .hold), ImageTimeFixtures.key(2, 9, 20, 30, .hold)])
        let shrunk = try ImageTimeFixtures.mapping(ImageTimeFixtures.layer(duration: 10, rule: small), visible: 0...2, fileDuration: 3)
        #expect(shrunk.segments.map(\.start) == [0, 1, 1] && shrunk.segments.map(\.end) == [0, 0, 2])
        let gapRule = try ImageTimeFixtures.rule([ImageTimeFixtures.key(0, 5, 0, 10, .hold), ImageTimeFixtures.key(5, 9, 10, 20, .hold)])
        let gap = try ImageTimeFixtures.mapping(ImageTimeFixtures.layer(duration: 10, rule: gapRule), visible: 0...2, fileDuration: 3)
        #expect(gap.segments.map(\.start) == [0, 2] && gap.segments.map(\.end) == [1, 2])
        let cases: [(ImageTimeMapping, [Int64], [Int64])] = [
            (expanded, [9, 10, 11, 20, 21], [0, 0, 10, 10, 21]), (shrunk, [0, 1, 2], [6, 6, 8]), (gap, [0, 1, 2], [0, 3, 3])
        ]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (map, frames, values) in cases {
                for _ in 0..<3 {
                    for index in frames.indices.reversed() {
                        group.addTask {
                            let value = try map.time(at: frames[index], frameRate: 1).microseconds
                            #expect(value == values[index] * 1_000_000)
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// 动画全部在文件外时补可见线性段；只有一个根可见帧时为零，区间外仍按根时间。
    @Test func emptyClippedTracksAndSingleFrameUseSourceFallbacks() throws {
        let rule = try ImageTimeFixtures.rule([ImageTimeFixtures.key(100, 110, 80, 90)])
        let map = try ImageTimeFixtures.mapping(ImageTimeFixtures.layer(rule: rule), visible: 0...10, fileDuration: 11)
        #expect(try map.time(at: 5, frameRate: 1).microseconds == 5_000_000)
        let single = try ImageTimeFixtures.mapping(ImageTimeFixtures.layer(rule: rule), visible: 4...4)
        #expect(single.segments.isEmpty)
        #expect(try single.time(at: 4, frameRate: 1) == .zero)
        #expect(try single.time(at: 5, frameRate: 1).microseconds == 5_000_000)
        let outside = try ImageTimeFixtures.mapping(ImageTimeFixtures.layer(), visible: 50...60)
        #expect(outside.segments.isEmpty)
        #expect(try outside.time(at: 10, frameRate: 1).microseconds == 10_000_000)
    }

    /// 准备预算、取消和极端数值失败；不能把越界Float转Int64或让无效帧率静默返回零。
    @Test func rejectsBudgetCancellationAndUnrepresentableMath() async throws {
        #expect(throws: PAGError.resourceLimitExceeded("maximumPreparedSceneBytes")) {
            try ImageTimeFixtures.mapping(ImageTimeFixtures.layer(), visible: 0...10, maximumBytes: 127)
        }
        #expect(throws: PAGError.self) { try ImageTimeFixtures.mapping(ImageTimeFixtures.layer(start: .max), visible: 0...10) }
        let enormous = try ImageTimeFixtures.rule([ImageTimeFixtures.key(0, 10, .max, .max)])
        #expect(throws: PAGError.self) { try ImageTimeFixtures.mapping(ImageTimeFixtures.layer(rule: enormous), visible: 0...10) }
        let map = try ImageTimeFixtures.mapping(ImageTimeFixtures.layer(), visible: 0...10)
        #expect(throws: PAGError.self) { try map.time(at: 1, frameRate: .leastNonzeroMagnitude) }
        #expect(throws: PAGError.self) { try map.time(at: 0, frameRate: 0) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try ImageTimeFixtures.mapping(ImageTimeFixtures.layer(), visible: 0...10) }
        }
        await task.value
    }
}
