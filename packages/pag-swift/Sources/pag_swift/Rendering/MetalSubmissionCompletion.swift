import Synchronization

/// GPU回调与提交前放弃共用的一次性出口；只同步纯值和continuation，不持有裸Metal对象。
final class MetalSubmissionCompletion: Sendable {
    /// 提交确认、可能提前到达的GPU结果和唯一等待者，仅在此短锁中转移所有权。
    private let state: Mutex<MetalSubmissionState>
    /// 此次绘制的显示信箱，负责让主actor异步等待平台访问排空。
    private let mailbox: DisplayTargetMailbox
    /// 只能归还自己的这一份租约，不触碰之后新帧的租约。
    private let lease: DisplayTargetLease

    /// 在申请drawable之前建立唯一清理出口，失败/不可用/提交完成都经过它。
    init(continuation: CheckedContinuation<Result<Bool, any Error>, Never>,
         mailbox: DisplayTargetMailbox, lease: DisplayTargetLease) {
        state = Mutex(MetalSubmissionState(continuation: continuation))
        self.mailbox = mailbox
        self.lease = lease
    }

    /// GPU回调可能早于commit返回，此时只保存结果，禁止递归取得仍被提交段持有的mailbox锁。
    func gpuFinished(_ result: Result<Bool, any Error>) {
        let completion = state.withLock { value -> MetalSubmissionResult? in
            guard value.continuation != nil, value.gpuResult == nil else { return nil }
            value.gpuResult = result
            return value.isCommitted ? value.takeResult(result) : nil
        }
        finish(completion)
    }

    /// 只在commit已经成功且离开双锁/drawable借用作用域后确认；若回调已到则在此完成清理。
    func didCommit() {
        let completion = state.withLock { value -> MetalSubmissionResult? in
            guard value.continuation != nil, !value.isCommitted else { return nil }
            value.isCommitted = true
            guard let result = value.gpuResult else { return nil }
            return value.takeResult(result)
        }
        finish(completion)
    }

    /// 未提交的失败或不可用立即结束；已确认提交则拒绝提前释放，仍须等GPU完成。
    @discardableResult func abandon(_ result: Result<Bool, any Error>) -> Bool {
        let completion = state.withLock { value -> MetalSubmissionResult? in
            guard !value.isCommitted else { return nil }
            return value.takeResult(result)
        }
        finish(completion)
        return completion != nil
    }

    /// 离开内部锁后归还租约再恢复等待；系统回调和owner确认只会有一个取到此值。
    private func finish(_ completion: MetalSubmissionResult?) {
        guard let completion else { return }
        mailbox.release(lease)
        completion.continuation.resume(returning: completion.result)
    }
}

/// 一次GPU提交的纯值同步状态，不包含command buffer或drawable别名。
private struct MetalSubmissionState {
    /// 唯一等待者，被结束路径取走后为nil。
    var continuation: CheckedContinuation<Result<Bool, any Error>, Never>?
    /// 已经到达的第一个GPU结果；nil表示仍未回调。
    var gpuResult: Result<Bool, any Error>?
    /// owner已经commit并退出提交临界段与drawable借用，之后禁止主动提前释放。
    var isCommitted = false

    /// 原子取走待完成值；迟到回调无法取得第二份continuation。
    mutating func takeResult(_ result: Result<Bool, any Error>) -> MetalSubmissionResult? {
        guard let continuation else { return nil }
        self.continuation = nil
        return MetalSubmissionResult(continuation: continuation, result: result)
    }
}

/// 从内部锁移出的唯一结束值，随后在锁外归还显示租约。
private struct MetalSubmissionResult {
    /// 恰好恢复一次的调用方等待者。
    let continuation: CheckedContinuation<Result<Bool, any Error>, Never>
    /// GPU完成或提交前放弃的实际结果。
    let result: Result<Bool, any Error>
}
