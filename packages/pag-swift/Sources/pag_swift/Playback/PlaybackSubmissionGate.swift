import Foundation
import Synchronization

/// 一次可呈现工作的完整身份；不含 View、纹理或共享可变场景。
struct PlaybackRequestToken: Sendable, Equatable {
    /// 内容帧的完整文件摘要；nil只用于无PAG文档的透明清屏。
    let documentID: DocumentIdentity?
    /// 对外可观察的合成提交代数，编辑与缩放更新后失效。
    let compositionRevision: UInt64
    /// seek/重播等控制撤销时生成的新身份，不以回绕计数代替。
    let playbackEpoch: UUID
    /// 挂载、尺寸或目标可用性变化时生成的新身份。
    let targetEpoch: UUID
    /// 单次工作身份，同一代数内的不同帧也不能交换完成结果。
    let requestID: UUID
}

/// 控制撤销与渲染 owner 最后提交共用的短锁门；不负责排队或等待 GPU。
final class PlaybackSubmissionGate: Sendable {
    /// 提交许可与同代数呈现许可共用一把锁；GPU 完成不能提前撤销实际呈现回调。
    private let permission = Mutex(PlaybackPermission())

    /// 调度器只为即将开始的唯一活动工作安装许可；待处理请求不能抢走旧帧许可。
    @discardableResult func allow(_ token: PlaybackRequestToken, unlessCancelled waiter: PlaybackRenderWaiter? = nil) -> Bool {
        permission.withLock { state in
            guard waiter?.isCancelled != true else { return false }
            state.submission = token
            state.presentation = token
            return true
        }
    }

    /// 同步撤销所有旧提交；返回之后旧请求不可能再进入持锁提交段。
    func revoke() {
        permission.withLock { $0 = PlaybackPermission() }
    }

    /// 只撤销指定请求，避免显式 render 的迟到取消误伤更新的工作。
    func revoke(_ token: PlaybackRequestToken) {
        permission.withLock { state in
            if state.submission == token { state.submission = nil }
            if state.presentation == token { state.presentation = nil }
        }
    }

    /// 在同一临界区撤销并取消显式等待；待处理工作随后也不能重新获取许可。
    func cancel(_ token: PlaybackRequestToken, waiter: PlaybackRenderWaiter) {
        permission.withLock { state in
            if state.submission == token { state.submission = nil }
            if state.presentation == token { state.presentation = nil }
            // 与 allow 使用同一锁序。恢复 continuation 只排入调用者执行域，不在这里等待调用者。
            waiter.cancel()
        }
    }

    /// 完成与同步取消竞争的线性化点；只有第一个消费有效许可的完成可以更新状态。
    func claimCompletion(_ token: PlaybackRequestToken) -> Bool {
        permission.withLock { state in
            guard state.submission == token else { return false }
            state.submission = nil
            return true
        }
    }

    /// 回调更新状态前检查完整身份；不能把此检查代替最后 enqueue 的锁内校验。
    func permits(_ token: PlaybackRequestToken) -> Bool {
        permission.withLock { $0.submission == token }
    }

    /// 与撤销互斥地验证并执行同步提交；失效返回 nil，提交错误原样传播。
    /// body 只能做已经准备好的 enqueue/present，不得 await、取 drawable 或等待 GPU。
    func withPermission<Result>(for token: PlaybackRequestToken,
                                _ body: () throws -> Result) rethrows -> Result? {
        try permission.withLock { state in
            guard state.submission == token else { return nil }
            return try body()
        }
    }

    /// GPU完成后与同步撤销互斥地执行极短缓存发布；不消费播放器后续状态完成许可。
    func withCompletionPermission<Result>(for token: PlaybackRequestToken,
                                          _ body: () -> Result) -> Result? {
        permission.withLock { state in
            guard state.submission == token else { return nil }
            // 锁内只允许小值状态或已完成纹理LRU操作，不得等待GPU、取drawable或await。
            return body()
        }
    }

    /// 系统呈现回调可晚于下一帧开始，但不能越过控制/文档/显示代数；body 只更新小值时钟。
    func withPresentationPermission<Result>(for token: PlaybackRequestToken, _ body: () -> Result) -> Result? {
        permission.withLock { state in
            guard let current = state.presentation,
                  current.documentID == token.documentID,
                  current.compositionRevision == token.compositionRevision,
                  current.playbackEpoch == token.playbackEpoch,
                  current.targetEpoch == token.targetEpoch else { return nil }
            return body()
        }
    }
}

/// 一个短锁同时串行化控制撤销与两种不同结束时刻的许可。
private struct PlaybackPermission {
    /// 当前唯一 GPU 工作；claimCompletion 消费后为空。
    var submission: PlaybackRequestToken?
    /// 最新允许呈现的代数代表；同代数早先请求仍可报告实际呈现。
    var presentation: PlaybackRequestToken?
}
