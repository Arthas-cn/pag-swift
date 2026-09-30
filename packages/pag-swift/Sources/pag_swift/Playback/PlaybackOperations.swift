import Foundation

/// 显示 owner 必须实现的实际提交边界；P4 没有返回虚假成功的生产默认实现。
protocol PlaybackSubmitting: Sendable {
    /// 求值并提交到绑定目标，等待 command buffer 完成；失效/主动取消抛 CancellationError。
    func submit(_ request: PlaybackFrameRequest) async throws -> PlaybackSubmission
}

/// 后台提交器返回的小值，不把 drawable 或纹理发送到控制 actor。
enum PlaybackSubmission: Sendable {
    /// 已通过 gate 且实际 GPU 工作正常完成；关联值为量化后的代表微秒。
    case submitted(PAGTime)
    /// 透明清屏已经通过同一许可并实际完成GPU工作，不代表任何PAG时间帧。
    case cleared
    /// 目标暂时不能呈现，需要等待下一次目标可用通知。
    case targetUnavailable
}

/// 某一帧完整的不可变输入，后台求值只能读取这份快照。
struct PlaybackFrameRequest: Sendable {
    /// 安装阶段准备的完整场景；nil表示清屏，此时token.documentID也必须为nil。
    let scene: PreparedScene?
    /// 内容帧按根时间合同量化；清屏固定为零，不参与时间轴。
    let time: PAGTime
    /// 最终合成到显示目标的映射模式。
    let scaleMode: PAGScaleMode
    /// 所有迟到拒绝需要的完整身份。
    let token: PlaybackRequestToken
    /// 提交前必须在同一短锁内校验并 enqueue/present。
    let gate: PlaybackSubmissionGate
    /// 内容请求可承担有限末帧，清屏必须为false，不改变empty或完成次数。
    let endsPlayback: Bool
}

/// 调度层依赖注入；默认准备真实资源，测试可以控制准备完成时间和单调时钟。
struct PlaybackOperations: Sendable {
    /// 不阻塞的单调微秒读取；display tick 使用同一时间原点。
    var now: @Sendable () -> UInt64
    /// 后台完整场景准备，不在控制 actor 中进行字体、图像或几何工作。
    var prepare: @Sendable (PAGComposition, PreparedScene?) async throws -> PreparedScene
    /// 可选内部诊断观察，不构成公开逐帧事件 API。
    var observe: @Sendable (PlaybackEvent) -> Void

    /// 建立独立单调原点与真实准备器；不创建计时循环或显示提交器。
    init() {
        let origin = ContinuousClock.now
        now = {
            let duration = origin.duration(to: .now).components
            guard duration.seconds >= 0 else { return 0 }
            let micros = UInt128(duration.seconds) * 1_000_000 + UInt128(max(duration.attoseconds, 0)) / 1_000_000_000_000
            return UInt64(min(micros, UInt128(UInt64.max)))
        }
        prepare = { try await PreparedScene.prepare($0, reusing: $1) }
        observe = { _ in }
    }
}

/// 控制器内部生命周期诊断，用于无真实睡眠的并发测试。
enum PlaybackEvent: Sendable, Equatable {
    /// 活动请求结束且状态更新完成；Bool 表示是否仍有有效提交许可。
    case workFinished(UUID, accepted: Bool)
    /// 订阅增加或终止后的存活数量，不包括已经取消的消费者。
    case subscriptionCount(Int)
}

/// 至多一份的待处理帧及其可选显式等待者；普通刷新不分配 continuation。
struct QueuedPlaybackFrame: Sendable {
    /// 后台任务需要的完整快照。
    let request: PlaybackFrameRequest
    /// 显式 render 等待者；nil 表示自动播放或普通控制请求。
    let waiter: PlaybackRenderWaiter?
}

/// 唯一活动工作与任务所有权；撤销后仍保留句柄直到迟到工作实际结束。
struct ActivePlaybackFrame: Sendable {
    /// 当前任务持有的请求及等待者。
    let frame: QueuedPlaybackFrame
    /// 可取消的后台任务，不为每一个 display tick 新建无主 Task。
    let task: Task<Void, Never>
}

/// 明确离开控制 actor 的后台调用边界，避免 nonisolated async 继承调用者执行器做重活。
enum PlaybackWork {
    /// 调用真正提交 owner 并封装结果；取消保持独立错误，不在这里改写播放状态。
    @concurrent static func execute(_ request: PlaybackFrameRequest,
                                    using submitter: any PlaybackSubmitting) async -> Result<PlaybackSubmission, any Error> {
        do { return .success(try await submitter.submit(request)) }
        catch { return .failure(error) }
    }
}
