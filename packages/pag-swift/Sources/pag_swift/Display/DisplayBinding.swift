import Foundation
import Synchronization

/// 一个播放器对表面的独占预约；仅含Sendable所有者与小值通道，不保活播放器。
final class DisplayBinding: Sendable {
    /// 每次预约都不同，旧清理不能解除新绑定。
    let id = UUID()
    /// 播放器稳定身份，用于拒绝其他仍有效的拥有者。
    let playerID: UUID
    /// 此表面唯一的后台渲染所有者。
    let owner: RenderOwner
    /// 显示代数与可用性的权威小值状态。
    let mailbox: DisplayTargetMailbox
    /// 合并目标状态与刷新时间的唯一消费流，每条消息都包含完整目标状态。
    let events: AsyncStream<DisplayBindingEvent>
    /// 播放意图变化的唯一消费流，主actor据此暂停实际display link。
    let tickRequests: AsyncStream<Bool>
    /// 显示消息生产端，取消时终止，不积累逐帧历史。
    private let eventContinuation: AsyncStream<DisplayBindingEvent>.Continuation
    /// 去重的播放意图生产端。
    private let tickContinuation: AsyncStream<Bool>.Continuation
    /// 与控制命令相同原点的单调微秒采样；主actor回调不访问播放器actor。
    private let now: @Sendable () -> UInt64
    /// 显式宿主调用的确认通道，弱引用控制器；返回时配置已在控制actor生效。
    private let notify: @Sendable (UUID, DisplayBindingEvent) async -> Void
    /// 同步撤销和播放意图，仅在短锁内读写纯值。
    private let state = Mutex(DisplayBindingState())
    /// 尚未撤销的预约；false之后不能重新激活。
    var isValid: Bool { state.withLock { $0.isValid } }
    /// 播放器仍有自动推进或恢复意图；实际启用还须通过表面可用性检查。
    var wantsTicks: Bool { state.withLock { $0.isValid && $0.wantsTicks } }
    /// 最近平台link建立结果；无显示屏时自动播放必须处于不可用状态。
    var isRefreshAvailable: Bool { state.withLock { $0.isRefreshAvailable } }

    /// 建立两个容量为1的流；不启动后台任务或触碰平台对象。
    init(playerID: UUID, owner: RenderOwner, mailbox: DisplayTargetMailbox, now: @escaping @Sendable () -> UInt64,
         notify: @escaping @Sendable (UUID, DisplayBindingEvent) async -> Void) {
        self.playerID = playerID
        self.owner = owner
        self.mailbox = mailbox
        self.now = now
        self.notify = notify
        let events = AsyncStream.makeStream(of: DisplayBindingEvent.self, bufferingPolicy: .bufferingNewest(1))
        self.events = events.stream
        eventContinuation = events.continuation
        let ticks = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        tickRequests = ticks.stream
        tickContinuation = ticks.continuation
    }

    /// 发布当前完整目标快照；tick才采样时间，状态变更不自行推进播放。
    func publish(tick: Bool = false, failure: PAGError? = nil) {
        guard isValid else { return }
        eventContinuation.yield(DisplayBindingEvent(target: mailbox.snapshot, time: tick ? now() : nil, failure: failure))
    }

    /// 显式尺寸/可见性操作等待控制状态接受；每帧刷新仍只走有界流。
    func synchronize(failure: PAGError? = nil) async {
        guard isValid else { return }
        await notify(id, DisplayBindingEvent(target: mailbox.snapshot, time: nil, failure: failure))
    }

    /// 只在意图实际改变时通知主actor，不因每帧snapshot发布产生额外调度。
    func requestTicks(_ value: Bool) {
        let changed = state.withLock { state in
            guard state.isValid, state.wantsTicks != value else { return false }
            state.wantsTicks = value
            return true
        }
        if changed { tickContinuation.yield(value) }
    }

    /// 发布真实刷新源是否存在；恢复屏幕后可以重新变为可用，不伪造定时tick。
    func setRefreshAvailable(_ available: Bool) {
        let changed = state.withLock { state in
            guard state.isValid, state.isRefreshAvailable != available else { return false }
            state.isRefreshAvailable = available
            return true
        }
        if changed { publish() }
    }

    /// 同步撤销并结束两个消费者；重复清理无效，迟到yield由已结束的流丢弃。
    func cancel() {
        let changed = state.withLock { state in
            guard state.isValid else { return false }
            state.isValid = false
            state.wantsTicks = false
            return true
        }
        if changed { eventContinuation.finish(); tickContinuation.finish() }
    }
}

/// 一次主actor显示通知；合并旧通知仍保留最新目标配置。
struct DisplayBindingEvent: Sendable {
    /// 发出通知时的显示代数与完整配置，消费者还需复核当前mailbox。
    let target: DisplayTargetSnapshot
    /// display tick的单调微秒；nil表示只有目标配置变化。
    let time: UInt64?
    /// 非取消的平台配置失败；nil为正常配置或刷新通知。
    let failure: PAGError?
}

/// 预约短锁中的状态，与系统display link分离。
private struct DisplayBindingState {
    /// 取消后永久为false，不能把旧绑定重新借给其他播放器。
    var isValid = true
    /// 控制actor最近发布的自动推进意图。
    var wantsTicks = false
    /// 尚未请求link时默认可用；真正请求后以平台创建结果为准。
    var isRefreshAvailable = true
}
