import Testing
@testable import pag_swift

/// 验证微秒、归一化进度、帧与可见区间之间的边界和溢出行为。
struct TimeMappingTests {
    /// 根定位钳到右开区间内，极端输入也不会越过末尾或整数溢出。
    @Test(arguments: [Int64.min, -1, 0, 5, 9, 10, .max])
    func rootSeekClampsToVisibleRange(_ requested: Int64) throws {
        let result = try TimeMapping.clamped(
            PAGTime(microseconds: requested), duration: PAGTime(microseconds: 10)
        )
        #expect(result.microseconds == min(max(requested, 0), 9))
    }

    /// 单微秒时长的所有进度都定位零，末进度仍留在可见范围内。
    @Test(arguments: [0.0, 0.25, 0.5, 1])
    func oneMicrosecondHasOnePosition(_ value: Double) throws {
        let result = try TimeMapping.time(
            for: PAGProgress(value), duration: PAGTime(microseconds: 1)
        )
        #expect(result == .zero)
    }

    /// 奇数时长中间定位向下取整，进度一为 duration-1 而不是结束点。
    @Test func progressMapsToMicroseconds() throws {
        let duration = PAGTime(microseconds: 101)
        #expect(try TimeMapping.time(for: .start, duration: duration).microseconds == 0)
        #expect(try TimeMapping.time(for: PAGProgress(0.5), duration: duration).microseconds == 50)
        #expect(try TimeMapping.time(for: .end, duration: duration).microseconds == 100)
    }

    /// 长时间轴必须保留整数精度；Double 转换不能把 Int64.max 舍入成不可转换的值。
    @Test func fullIntegerRangeProgressRemainsExact() throws {
        let duration = PAGTime(microseconds: .max)
        #expect(try TimeMapping.time(for: PAGProgress(0.5), duration: duration).microseconds
            == Int64.max / 2)
        #expect(try TimeMapping.time(for: .end, duration: duration).microseconds == Int64.max - 1)
        // 1.nextDown 等于 1 - 2^-53；最大时长的精确 floor 比最大值少 1024。
        #expect(try TimeMapping.time(for: PAGProgress(1.0.nextDown), duration: duration).microseconds
            == Int64.max - 1024)
        #expect(try TimeMapping.time(for: PAGProgress(.leastNonzeroMagnitude), duration: duration)
            == .zero)
    }

    /// 根时间轴拒绝零和负时长，不能靠钳制掩盖无效文档。
    @Test(arguments: [Int64.min, -1, 0])
    func rootMappingRejectsInvalidDuration(_ value: Int64) {
        let duration = PAGTime(microseconds: value)
        #expect(throws: PAGError.invalidArgument("duration")) {
            try TimeMapping.clamped(.zero, duration: duration)
        }
        #expect(throws: PAGError.invalidArgument("duration")) {
            try TimeMapping.time(for: .end, duration: duration)
        }
    }

    /// 图层负起点合法，起点可见、终点不可见，零时长不占任何时间。
    @Test func layerVisibilityUsesHalfOpenRange() throws {
        let start = PAGTime(microseconds: -10)
        let duration = PAGTime(microseconds: 20)
        #expect(try TimeMapping.contains(start, start: start, duration: duration))
        #expect(try TimeMapping.contains(.zero, start: start, duration: duration))
        #expect(try TimeMapping.contains(PAGTime(microseconds: 10), start: start, duration: duration) == false)
        #expect(try TimeMapping.contains(start, start: start, duration: .zero) == false)
    }

    /// 可见区间终点溢出必须报告错误，不能回绕到负时间。
    @Test func intervalEndRejectsOverflowAndNegativeDuration() {
        #expect(throws: PAGError.invalidArgument("timeRange")) {
            try TimeMapping.end(start: PAGTime(microseconds: .max), duration: PAGTime(microseconds: 1))
        }
        #expect(throws: PAGError.invalidArgument("duration")) {
            try TimeMapping.end(start: .zero, duration: PAGTime(microseconds: -1))
        }
    }

    /// 30fps 的边界遵守上游 floor/ceil，负时间不能按向零截断。
    @Test func frameQuantizationMatchesUpstreamBoundaries() throws {
        #expect(try TimeMapping.frame(at: PAGTime(microseconds: 33_333), frameRate: 30) == 0)
        #expect(try TimeMapping.frame(at: PAGTime(microseconds: 33_334), frameRate: 30) == 1)
        #expect(try TimeMapping.frame(at: PAGTime(microseconds: -1), frameRate: 30) == -1)
        #expect(try TimeMapping.time(forFrame: 1, frameRate: 30).microseconds == 33_334)
        #expect(try TimeMapping.time(forFrame: -1, frameRate: 30).microseconds == -33_333)
        #expect(try TimeMapping.time(forFrame: 450, frameRate: 30).microseconds == 15_000_000)
    }

    /// 非整数帧率不应被强改成整数，常规帧往返仍定位到同一帧。
    @Test(arguments: [23.976, 29.97, 59.94, 120.0])
    func fractionalFrameRatesRoundTrip(_ frameRate: Double) throws {
        for frame: Int64 in [-100, -1, 0, 1, 100] {
            let time = try TimeMapping.time(forFrame: frame, frameRate: frameRate)
            #expect(try TimeMapping.frame(at: time, frameRate: frameRate) == frame)
        }
    }

    /// 非有限或非正帧率在运算前失败，不能触发整数转换陷阱。
    @Test(arguments: [0.0, -1, .nan, .infinity, -.infinity])
    func frameRatesAreValidated(_ value: Double) {
        #expect(throws: PAGError.invalidArgument("frameRate")) {
            try TimeMapping.frame(at: .zero, frameRate: value)
        }
        #expect(throws: PAGError.invalidArgument("frameRate")) {
            try TimeMapping.time(forFrame: 0, frameRate: value)
        }
    }

    /// 超大时间或帧率产生的不可表示结果必须返回错误，不能执行有陷阱的转换。
    @Test func frameConversionsRejectUnrepresentableResults() {
        #expect(throws: PAGError.invalidArgument("frameRange")) {
            try TimeMapping.frame(at: PAGTime(microseconds: .max), frameRate: .greatestFiniteMagnitude)
        }
        #expect(throws: PAGError.invalidArgument("timeRange")) {
            try TimeMapping.time(forFrame: .max, frameRate: .leastNonzeroMagnitude)
        }
    }
}
