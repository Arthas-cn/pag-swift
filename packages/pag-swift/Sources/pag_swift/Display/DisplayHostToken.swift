import Synchronization

/// 一次原生宿主的绑定意图；只承载撤销值，不保活View、surface或播放器。
final class DisplayHostToken: Sendable {
    /// 主actor可同步撤销，控制actor每次接受绑定或失败前读取。
    private let validity = Mutex(true)

    /// 身份是否仍可安装新绑定或发布失败；撤销后永不恢复。
    var isValid: Bool { validity.withLock { $0 } }

    /// 宿主被替换或销毁时立即撤销，迟到actor消息不再影响新宿主。
    func cancel() { validity.withLock { $0 = false } }
}
