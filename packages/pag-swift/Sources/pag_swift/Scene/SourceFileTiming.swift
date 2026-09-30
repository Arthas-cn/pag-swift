/// 文件总时长被编辑后的源适配模式；不控制播放器的整文件重复次数。
enum SourceTimeStretchMode: UInt8, Sendable {
    /// 保持原速度，目标时长更长时保持最后一帧。
    case none = 0
    /// 调整源内容速度以适配目标时长，可受文件范围约束。
    case scale = 1
    /// 保持原速度，目标时长更长时正向重复；上游文件默认值。
    case `repeat` = 2
    /// 保持原速度，目标时长更长时交替正向和反向重复。
    case repeatInverted = 3
}

/// 文件原始时间范围；按ReadTime保留帧值，允许空范围，不把它当微秒或Swift Range。
struct SourceTimeRange: Sendable, Equatable {
    /// 编码起点，尚未应用上游至少为0的规范化。
    let start: Int64
    /// 编码终点，尚未应用上游至多为根帧时长的规范化。
    let end: Int64
}

/// 源文件的只读时间设置；当前总时长不支持编辑，因此这些值不改变播放采样。
struct SourceFileTiming: Sendable {
    /// 总时长被编辑时的源适配方式，缺少tag32时为Repeat。
    let mode: SourceTimeStretchMode
    /// 原始指定范围；nil表示默认覆盖原始根合成全帧区间。
    let scaledRange: SourceTimeRange?

    /// 保存已经验证的枚举及可选原始帧范围，不在元数据构造时执行时间映射。
    init(mode: SourceTimeStretchMode = .repeat, scaledRange: SourceTimeRange? = nil) {
        self.mode = mode
        self.scaledRange = scaledRange
    }
}
