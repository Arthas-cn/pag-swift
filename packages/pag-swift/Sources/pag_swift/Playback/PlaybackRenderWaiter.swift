import Synchronization

/// 显式 render 的单次完成门闩；调用者取消不必等待不可撤回的 GPU 工作结束。
final class PlaybackRenderWaiter: Sendable {
    /// 取消、结果和 continuation 的互斥状态，恢复动作始终移到锁外。
    private let state = Mutex<PlaybackWaiterState>(.pending(nil))

    /// 安装唯一等待；先到达的取消或结果会立即恢复，重复等待属于内部编程错误。
    func value() async throws -> PAGRenderResult {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<PAGRenderResult, any Error>? = state.withLock { state in
                switch state {
                case .pending(let existing):
                    precondition(existing == nil, "显式帧只能等待一次")
                    state = .pending(continuation)
                    return nil
                case .resolved(let result): return result
                }
            }
            if let result { continuation.resume(with: result) }
        }
    }

    /// 只接受第一个终态，完成/撤销竞争不能双重恢复。
    func resolve(_ result: Result<PAGRenderResult, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<PAGRenderResult, any Error>? in
            guard case .pending(let continuation) = state else { return nil }
            state = .resolved(result)
            return continuation
        }
        continuation?.resume(with: result)
    }

    /// 同步结束当前调用者的等待；取消不会被包装为主播放错误。
    func cancel() {
        resolve(.failure(CancellationError()))
    }

    /// 等待者已取消时禁止随后安装提交许可，封住取消发生在待处理阶段的竞争窗口。
    var isCancelled: Bool {
        state.withLock { state in
            if case .resolved(.failure(let error)) = state { return error is CancellationError }
            return false
        }
    }
}

/// 显式帧等待的两种状态，未开始等待也能提前完成或取消。
private enum PlaybackWaiterState {
    /// 正在等待结果；nil 表示尚未安装 continuation。
    case pending(CheckedContinuation<PAGRenderResult, any Error>?)
    /// 已完成或主动取消，保留唯一结果供迟到的 value 读取。
    case resolved(Result<PAGRenderResult, any Error>)
}
