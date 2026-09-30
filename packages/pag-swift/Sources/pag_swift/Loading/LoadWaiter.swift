import Synchronization

/// 单个调用者的完成门闩；同步取消与 actor 完成竞争时只恢复 continuation 一次。
final class LoadWaiter: Sendable {
    /// 所有可变状态仅在 Mutex 内访问；没有未审计的 Sendable 绕过。
    private let state = Mutex<WaiterState>(.pending(nil))

    /// 安装一次等待；取消或完成先到达时立即恢复，不依赖回调执行顺序。
    func value() async throws -> PAGFile {
        try await withCheckedThrowingContinuation { continuation in
            let immediate: Result<PAGFile, any Error>? = state.withLock { state in
                switch state {
                case .pending(let existing):
                    precondition(existing == nil, "一个请求只能安装一次等待")
                    state = .pending(continuation)
                    return nil
                case .resolved(let result):
                    return result
                case .cancelled:
                    return .failure(CancellationError())
                }
            }
            // continuation 恢复放在锁外，不把调用方的后续执行带进临界区。
            if let immediate { continuation.resume(with: immediate) }
        }
    }

    /// 同步撤销此等待者；已完成时保持先完成语义，不影响其他等待者。
    func cancel() {
        let continuation = state.withLock { state -> CheckedContinuation<PAGFile, any Error>? in
            guard case .pending(let continuation) = state else { return nil }
            state = .cancelled
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    /// 提交唯一终态，返回是否仍有接收者；返回 false 的结果不能作为仅有等待者的缓存依据。
    @discardableResult func resolve(_ result: Result<PAGFile, any Error>) -> Bool {
        let outcome = state.withLock { state -> (Bool, CheckedContinuation<PAGFile, any Error>?) in
            guard case .pending(let continuation) = state else { return (false, nil) }
            state = .resolved(result)
            return (true, continuation)
        }
        outcome.1?.resume(with: result)
        return outcome.0
    }

    /// 是否已由取消赢得终态；actor 用于开始共享任务前的检查。
    var isCancelled: Bool {
        state.withLock { state in
            if case .cancelled = state { return true }
            return false
        }
    }
}

/// 完成门闩的互斥状态；每条路径最多拿到一次待恢复 continuation。
private enum WaiterState {
    /// 尚未完成；nil 表示 value 尚未安装 continuation。
    case pending(CheckedContinuation<PAGFile, any Error>?)
    /// 完成先于取消；保留结果使迟到的 value 能立即返回。
    case resolved(Result<PAGFile, any Error>)
    /// 取消先于完成；后续解析结果必须被此等待者丢弃。
    case cancelled
}
