/// 播放控制层当前可观察的状态；playing 不承诺每个请求都已显示。
public enum PAGPlaybackState: Sendable, Hashable {
    /// 尚未安装合成，不能开始播放。
    case empty
    /// 已安装合成，尚未建立自动推进的播放意图。
    case ready
    /// 有播放意图且显示目标可用；也包含等待最后一帧提交的短暂状态。
    case playing
    /// 主动暂停或 stop，保留当前位置和已完成次数。
    case paused
    /// 有播放意图但目标暂不可用；隐藏时间不会计入下一次推进。
    case suspended
    /// 指定总次数已完成，且最后可见帧已有效提交。
    case finished
    /// 主播放发生不可恢复错误，错误详情保留在快照中。
    case failed
}

/// 播放控制层发布的不可变值；请求位置与最近有效提交时间可以不同。
public struct PAGPlaybackSnapshot: Sendable {
    /// 当前控制状态，不以 GPU 完成回调改写新的播放意图。
    public let state: PAGPlaybackState
    /// 最近接受且已钳制的根请求微秒；没有合成时为零。
    public let position: PAGTime
    /// 最近有效提交的量化帧时间；尚未提交当前合成时为 nil。
    public let presentedTime: PAGTime?
    /// 当前根合成的正时长；没有合成时为 nil。
    public let duration: PAGTime?
    /// 完整跨过根合成终点的次数；无限循环达到 UInt64.max 后饱和。
    public let completedIterations: UInt64
    /// 总播放次数配置；小于等于零表示无限循环。
    public let repeatCount: Int
    /// 当前合成提交代数，单调递增且不回绕。
    public let revision: UInt64
    /// 当前主工作错误；主动取消不进入此字段。
    public let failure: PAGError?
}

/// 显式绘制的有效提交结果，不携带像素或离屏图像。
public enum PAGRenderResult: Sendable, Hashable {
    /// 对应代数的 command buffer 正常完成；时间是实际量化帧的代表微秒。
    case submitted(time: PAGTime, revision: UInt64)
    /// 当前目标不能呈现，未生成替代离屏结果。
    case targetUnavailable
}
