/// 以微秒表示的有符号时间，允许表示图层在父时间轴上的负起点。
public struct PAGTime: Sendable, Hashable, Comparable {
    /// 精确保留的微秒值；不是帧号或归一化进度。
    public let microseconds: Int64

    /// 保留任意 Int64 微秒，具体时间轴的范围由使用位置验证。
    public init(microseconds: Int64) {
        self.microseconds = microseconds
    }

    /// 时间轴原点。
    public static let zero = PAGTime(microseconds: 0)

    /// 按微秒先后比较，不进行可能溢出的相减。
    public static func < (lhs: PAGTime, rhs: PAGTime) -> Bool {
        lhs.microseconds < rhs.microseconds
    }
}

/// 已验证为有限闭区间 0...1 的定位进度，与绝对微秒时间分开表示。
public struct PAGProgress: Sendable, Hashable {
    /// 通过初始化校验的归一化定位值。
    public let value: Double

    /// 接受 0...1 的有限值，否则抛出 invalidArgument("progress")。
    public init(_ value: Double) throws {
        guard value.isFinite, (0...1).contains(value) else {
            throw PAGError.invalidArgument("progress")
        }
        self.value = value
    }

    /// 指向第一帧的请求。
    public static let start = PAGProgress(validatedValue: 0)

    /// 指向最后可见时刻的请求，而不是右开区间之外的时刻。
    public static let end = PAGProgress(validatedValue: 1)

    /// 仅构造本类型固定的合法端点，外部输入必须经过公开校验。
    private init(validatedValue: Double) {
        value = validatedValue
    }
}
