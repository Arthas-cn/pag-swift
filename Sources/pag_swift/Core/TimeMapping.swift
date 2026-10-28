/// 纯值时间计算层，统一根定位、右开可见区间和帧量化，不推进播放时钟。
enum TimeMapping {
    /// 把根定位钳到正时长的最后可见微秒；非正时长抛 invalidArgument。
    static func clamped(_ time: PAGTime, duration: PAGTime) throws -> PAGTime {
        let last = try lastMicrosecond(duration: duration)
        return PAGTime(microseconds: min(max(time.microseconds, 0), last))
    }

    /// 按 floor(progress × duration) 定位；进度 1 特别映射到最后可见微秒。
    static func time(for progress: PAGProgress, duration: PAGTime) throws -> PAGTime {
        let last = try lastMicrosecond(duration: duration)
        if progress.value == 1 { return PAGTime(microseconds: last) }
        if progress.value == 0 { return .zero }

        // Double 无法精确容纳 Int64 全范围。把已验证比例分解为二进制有理数，
        // 以最多 116 位的整数乘积计算 floor，避免长时间轴末端越界或丢失微秒。
        let bits = progress.value.bitPattern
        let exponent = Int((bits >> 52) & 0x7ff)
        let fraction = bits & 0x000f_ffff_ffff_ffff
        let significand = exponent == 0 ? fraction : fraction | (1 << 52)
        let shift = exponent == 0 ? 1074 : 1075 - exponent
        let product = UInt128(UInt64(duration.microseconds)) * UInt128(significand)

        // 极小的次正规比例乘任意合法时长仍小于一微秒，不能用过大的位移计数。
        guard shift < 128 else { return .zero }
        let microseconds = Int64(product >> shift)
        return PAGTime(microseconds: min(microseconds, last))
    }

    /// 计算右开区间终点；负时长或 Int64 加法溢出时抛 invalidArgument。
    static func end(start: PAGTime, duration: PAGTime) throws -> PAGTime {
        guard duration.microseconds >= 0 else { throw PAGError.invalidArgument("duration") }
        let (end, overflow) = start.microseconds.addingReportingOverflow(duration.microseconds)
        guard overflow == false else { throw PAGError.invalidArgument("timeRange") }
        return PAGTime(microseconds: end)
    }

    /// 判断时刻是否位于父时间轴的右开区间；零时长永远不可见。
    static func contains(_ time: PAGTime, start: PAGTime, duration: PAGTime) throws -> Bool {
        let end = try end(start: start, duration: duration)
        return time >= start && time < end
    }

    /// 把微秒按帧率向下量化；无效帧率或超出 Int64 帧号时抛 invalidArgument。
    static func frame(at time: PAGTime, frameRate: Double) throws -> Int64 {
        try validate(frameRate: frameRate)
        // 证据：libpag src/base/utils/TimeUtil.h::TimeToFrame。
        // 保持上游乘除顺序与 floor，包括负时间；转换前检查范围，避免整数陷阱。
        let value = (Double(time.microseconds) * frameRate / 1_000_000).rounded(.down)
        guard let frame = Int64(exactly: value) else {
            throw PAGError.invalidArgument("frameRange")
        }
        return frame
    }

    /// 取指定帧开始位置的代表微秒，向上取整；非法或越界时抛 invalidArgument。
    static func time(forFrame frame: Int64, frameRate: Double) throws -> PAGTime {
        try validate(frameRate: frameRate)
        // 证据：libpag src/base/utils/TimeUtil.h::FrameToTime。
        // ceil 使返回值在重新定位时属于该帧，不把浮点除法截断到前一帧。
        let value = (Double(frame) * 1_000_000 / frameRate).rounded(.up)
        guard let microseconds = Int64(exactly: value) else {
            throw PAGError.invalidArgument("timeRange")
        }
        return PAGTime(microseconds: microseconds)
    }

    /// 校验正时长后返回最后可见微秒，先校验再减一以免下溢。
    private static func lastMicrosecond(duration: PAGTime) throws -> Int64 {
        guard duration.microseconds > 0 else { throw PAGError.invalidArgument("duration") }
        return duration.microseconds - 1
    }

    /// 确认帧率有限且为正，禁止除零或将 NaN 传入整数转换。
    private static func validate(frameRate: Double) throws {
        guard frameRate.isFinite, frameRate > 0 else {
            throw PAGError.invalidArgument("frameRate")
        }
    }
}
