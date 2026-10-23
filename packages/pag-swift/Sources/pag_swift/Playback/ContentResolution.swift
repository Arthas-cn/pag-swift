import Foundation
import Synchronization

/// 超时由库独立结束等待，不要求宿主抛出取消错误。
enum ContentResolutionError: Error {
    /// 本次请求的等待期限已到。
    case timedOut
}

/// 一次性结果门闩；取消、超时及 provider 完成竞争时只唤醒一次。
final class ContentResolutionGate: Sendable {
    /// 所有状态均在同一同步锁内，禁止 continuation 双恢复。
    private let state = Mutex<ContentResolutionState>(ContentResolutionState())

    /// 安装唯一等待者；结果早到时立即恢复，不持锁恢复协程。
    func value() async -> Result<DynamicContent, any Error> {
        await withCheckedContinuation { continuation in
            let result: Result<DynamicContent, any Error>? = state.withLock { state in
                if let result = state.result { return result }
                precondition(state.continuation == nil)
                state.continuation = continuation
                return nil
            }
            if let result { continuation.resume(returning: result) }
        }
    }

    /// 首个终态生效，返回 false 表示结果迟到；不保留无用的迟到素材。
    @discardableResult func resolve(_ result: Result<DynamicContent, any Error>) -> Bool {
        let outcome = state.withLock { state in
            guard state.result == nil else { return (false, nil as CheckedContinuation<Result<DynamicContent, any Error>, Never>?) }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return (true, continuation)
        }
        outcome.1?.resume(returning: result)
        return outcome.0
    }
}

/// 仅存于门闩 Mutex 内的可变一次性状态。
private struct ContentResolutionState {
    /// value 尚未调用时为 nil；完成后清除以释放调用者。
    var continuation: CheckedContinuation<Result<DynamicContent, any Error>, Never>?
    /// 首个已接受的终态；nil 表示仍可接受完成或撤销。
    var result: Result<DynamicContent, any Error>?
}

/// 每播放器最多保留十六个实际未退出的宿主调用；超时不会归还此配额。
final class ContentProviderCapacity: Sendable {
    /// 同步工作计数可由任意执行器归还，生命周期可长于播放器。
    private let count = Mutex<Int>(0)

    /// 请求一个真实调用名额，耗尽时明确失败而非继续建立无界后台任务。
    func acquire() -> Bool {
        count.withLock {
            guard $0 < 16 else { return false }
            $0 += 1
            return true
        }
    }

    /// 只有 provider 真正返回才归还，取消请求本身不代表宿主工作结束。
    func release() { count.withLock { $0 -= 1 } }
}

/// 异步宿主解析边界，既不阻塞播放器 actor，也不等待不合作的宿主退出。
enum ContentResolution {
    /// 有界调用 provider 及可选 URL 回调；取消/超时立即解除播放器等待。
    @concurrent static func run(slot: PAGContentSlot, provider: @escaping PAGContentProvider,
        loadImage: (@Sendable (URL) async throws -> PAGImage)?, token: ContentRequestToken,
        timeout: Duration, gate: ContentResolutionGate, capacity: ContentProviderCapacity,
        log: ContentEventLog) async -> Result<DynamicContent, any Error> {
        if Task.isCancelled { return .failure(CancellationError()) }
        let deadline = token.started.advanced(by: timeout)
        guard ContinuousClock.now < deadline else { return .failure(ContentResolutionError.timedOut) }
        guard capacity.acquire() else { return .failure(PAGError.resourceLimitExceeded("outstandingContentProviders")) }
        // 必须脱离请求的结构化等待：不合作的宿主不能让超时任务组永远无法退出。
        // 名额由此真实 worker 退出时归还；worker 不捕获播放器或文档快照。
        let worker = Task.detached {
            defer { capacity.release() }
            let result: Result<DynamicContent, any Error>
            do {
                try Task.checkCancellation()
                var content = try await provider(slot)
                if case .imageURL(let url, let options) = content {
                    guard slot.kind == .image else { throw PAGError.invalidArgument("dynamicContentKind") }
                    guard let loadImage else { throw PAGError.invalidArgument("loadImageFromURL") }
                    try Task.checkCancellation()
                    content = .image(try await loadImage(url), options: options)
                }
                result = .success(content)
            } catch { result = .failure(error) }
            if !gate.resolve(result) {
                let content: DynamicContent? = if case .success(let value) = result { value } else { nil }
                log.record(token, .discarded, detail: "lateProviderResult", content: content)
            }
        }
        let timer = Task.detached {
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
                gate.resolve(.failure(ContentResolutionError.timedOut))
            } catch { /* 正常完成撤销超时任务，不生成另一条失败。 */ }
        }
        defer { worker.cancel(); timer.cancel() }
        return await withTaskCancellationHandler {
            await gate.value()
        } onCancel: {
            gate.resolve(.failure(CancellationError()))
            worker.cancel()
        }
    }
}
