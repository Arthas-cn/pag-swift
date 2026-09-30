/// 不含平台对象的显示可用性；detached 与暂时不可用具有不同的 play 错误语义。
enum PlaybackTargetState: Sendable, Equatable {
    /// 没有绑定显示目标，play 必须抛 missingSurface。
    case detached
    /// 已绑定但隐藏、零尺寸或暂时拿不到 drawable。
    case unavailable
    /// 目标可以接受一次显示请求，不保证未来每次 drawable 都立即可得。
    case available
}

/// 播放控制层的纯时间状态机；只接收单调微秒，不调度任务或声明 GPU 成功。
struct PlaybackTimeline: Sendable {
    /// 当前状态，初始没有合成。
    private(set) var state: PAGPlaybackState = .empty
    /// 已接受的根请求微秒，安装合成后始终处于右开有效区间。
    private(set) var position: PAGTime = .zero
    /// 当前正时长；nil 表示没有合成。
    private(set) var duration: PAGTime?
    /// 实际跨过根终点的整轮次数，无限循环时采用饱和计数。
    private(set) var completedIterations: UInt64 = 0
    /// 总次数而非额外重复次数；默认完整播放一次。
    private(set) var repeatCount = 1
    /// 主动播放意图；窗口恢复不能把 false 改成 true。
    private(set) var wantsPlayback = false
    /// 终点已经接受，但必须等有效末帧提交才能发布 finished。
    private(set) var awaitsFinalFrame = false
    /// 显示目标的当前可用性，安装合成不会清除此值。
    private(set) var target: PlaybackTargetState = .detached
    /// 主播放错误；只有安装完整合成才清除，取消不写入。
    private(set) var failure: PAGError?
    /// 最近一次已计入位置的单调微秒；不推进或等待末帧时为 nil。
    private var anchor: UInt64?
    /// 自然到达有限终点时该轮已经计数；撤销收尾继续播放不能再计同一个边界。
    private var creditedEndpoint = false

    /// 原子安装正时长或清空合成；非法时长在任何状态改变前失败。
    mutating func install(duration: PAGTime?) throws {
        if let duration, duration.microseconds <= 0 { throw PAGError.invalidArgument("duration") }
        self.duration = duration
        position = .zero
        completedIterations = 0
        wantsPlayback = false
        awaitsFinalFrame = false
        failure = nil
        anchor = nil
        creditedEndpoint = false
        state = duration == nil ? .empty : .ready
    }

    /// 接受同文档的新时长并保留时间/次数/播放意图；成功替换同时清除旧主错误。
    mutating func replace(duration: PAGTime, at now: UInt64) throws {
        let clamped = try TimeMapping.clamped(position, duration: duration)
        guard self.duration != nil else { throw PAGError.missingComposition }
        self.duration = duration
        position = clamped
        failure = nil
        if state == .failed { state = .paused }
        anchor = state == .playing && !awaitsFinalFrame ? now : nil
    }

    /// 更新显示生命周期，离开可用状态前采样一次，恢复时不累积隐藏时间。
    mutating func setTarget(_ target: PlaybackTargetState, at now: UInt64) {
        guard target != self.target else { return }
        advance(to: now)
        self.target = target
        if wantsPlayback {
            state = target == .available ? .playing : .suspended
            anchor = target == .available && !awaitsFinalFrame ? now : nil
        }
    }

    /// 从当前位置建立播放意图；仅直接重播 finished 才重置位置和次数。
    @discardableResult mutating func play(at now: UInt64) throws -> Bool {
        try requireUsableComposition()
        guard target != .detached else { throw PAGError.missingSurface }
        guard !wantsPlayback else { return false }
        if state == .finished {
            position = .zero
            completedIterations = 0
            awaitsFinalFrame = false
            creditedEndpoint = false
        }
        wantsPlayback = true
        state = target == .available ? .playing : .suspended
        anchor = state == .playing && !awaitsFinalFrame ? now : nil
        return true
    }

    /// 在控制命令时刻采样后冻结；已接受位置保留，收尾意图不越过主动暂停。
    mutating func pause(at now: UInt64) {
        advance(to: now)
        wantsPlayback = false
        awaitsFinalFrame = false
        anchor = nil
        if duration != nil, state != .failed { state = .paused }
    }

    /// 暂停并回到起点，清零整轮次数；失败场景须先成功安装/替换合成。
    mutating func rewind() throws {
        try requireUsableComposition()
        position = .zero
        completedIterations = 0
        wantsPlayback = false
        awaitsFinalFrame = false
        anchor = nil
        state = .paused
        creditedEndpoint = false
    }

    /// 钳制请求位置并重建推进锚点；定位本身不消耗次数，也不改变播放意图。
    mutating func seek(to time: PAGTime, at now: UInt64) throws {
        try requireUsableComposition()
        guard let duration else { throw PAGError.missingComposition }
        position = try TimeMapping.clamped(time, duration: duration)
        awaitsFinalFrame = false
        creditedEndpoint = false
        if state == .finished { state = .paused }
        anchor = state == .playing ? now : nil
    }

    /// 设置总播放次数；减少到已完成数量时发起末帧收尾，增加可撤销尚未提交的收尾。
    mutating func setRepeatCount(_ count: Int, at now: UInt64) {
        guard count != repeatCount else { return }
        advance(to: now)
        repeatCount = count
        guard let duration, state != .failed else { return }
        if count > 0, completedIterations >= UInt64(count) {
            // 配置变更也不能伪报末帧成功；即使当前暂停，也要通过一次有效提交结束。
            if !awaitsFinalFrame { creditedEndpoint = false }
            position = PAGTime(microseconds: duration.microseconds - 1)
            awaitsFinalFrame = true
            wantsPlayback = true
            state = target == .available ? .playing : .suspended
            anchor = nil
        } else if awaitsFinalFrame {
            awaitsFinalFrame = false
            anchor = state == .playing ? now : nil
        }
    }

    /// 以单调经过时间推进并计算跨轮次数；重复或倒序 tick 不修改锚点。
    @discardableResult mutating func advance(to now: UInt64) -> Bool {
        guard state == .playing, !awaitsFinalFrame, let anchor, now > anchor,
              let duration else { return false }
        let length = UInt128(duration.microseconds)
        let elapsed = UInt128(now - anchor) + UInt128(position.microseconds)
        let crossings = elapsed / length
        // 等末帧期间位置停在最后可见微秒，但自然终点已计数；恢复后的首个边界只能消费一次。
        let newCrossings = creditedEndpoint && crossings > 0 ? crossings - 1 : crossings
        let iterations = UInt128(completedIterations) + newCrossings
        if repeatCount > 0, crossings > 0, iterations >= UInt128(repeatCount) {
            position = PAGTime(microseconds: duration.microseconds - 1)
            completedIterations = max(completedIterations, UInt64(repeatCount))
            awaitsFinalFrame = true
            creditedEndpoint = true
            self.anchor = nil
        } else {
            position = PAGTime(microseconds: Int64(elapsed % length))
            completedIterations = UInt64(min(iterations, UInt128(UInt64.max)))
            self.anchor = now
            if crossings > 0 { creditedEndpoint = false }
        }
        return true
    }

    /// 只由已通过请求代数校验的末帧完成调用；其他完成不能改变控制状态。
    mutating func didSubmitFinalFrame() {
        guard awaitsFinalFrame else { return }
        awaitsFinalFrame = false
        wantsPlayback = false
        anchor = nil
        state = .finished
    }

    /// 主工作不可恢复失败时冻结，保留最后接受的位置与次数供诊断。
    mutating func fail(_ error: PAGError) {
        failure = error
        wantsPlayback = false
        awaitsFinalFrame = false
        anchor = nil
        state = .failed
    }

    /// 校验控制操作所需的完整合成；主动取消由调度层独立处理。
    private func requireUsableComposition() throws {
        guard duration != nil else { throw PAGError.missingComposition }
        if let failure { throw failure }
    }
}
