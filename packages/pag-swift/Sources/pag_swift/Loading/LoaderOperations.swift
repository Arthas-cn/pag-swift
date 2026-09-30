import Foundation

/// 可替换的内部 IO/解码边界；测试可控制暂停点，public API 不暴露执行器或假解码器。
struct LoaderOperations: Sendable {
    /// 从 URL 取得本次独立稳定快照；默认实现显式离开调用 actor。
    var read: @Sendable (URL, PAGLoadLimits) async throws -> LoadSnapshot = {
        try await StableFileReader.read(from: $0, limits: $1)
    }
    /// 为内存值准备完整摘要，不在 loader actor 上计算哈希。
    var prepare: @Sendable (Data, PAGLoadLimits) async throws -> LoadSnapshot = {
        try await LoadSnapshot.prepare(data: $0, limits: $1)
    }
    /// 只返回完整验证的文档；默认复用准备阶段的摘要。
    var decode: @Sendable (LoadSnapshot, PAGLoadLimits) async throws -> PAGFile = {
        try await PAGSceneDecoder.decode($0.data, limits: $1, identity: $0.identity)
    }
    /// 内部诊断事件接收器，默认无操作；必须快速返回，不能重入 loader 同步等待。
    var observe: @Sendable (LoaderEvent) -> Void = { _ in }
}

/// 可用于确定性并发验证的内部生命周期事件，不作为 public 状态 API。
enum LoaderEvent: Sendable, Equatable {
    /// 请求加入共享解析；关联值为该 flight 当前等待者数。
    case joined(Int)
    /// flight 完成或最后等待者离开，已从 loader 的在途表移除。
    case retired
    /// 已取消并移除的 flight 仍返回了结果，结果已丢弃。
    case discarded
}

/// Loader actor 的一致诊断快照，数值表示计费/所有权而非 allocator 峰值。
struct LoaderDiagnostics: Sendable {
    /// 当前缓存条目数。
    let cachedFiles: Int
    /// 缓存中保守计费字节的总和。
    let cachedBytes: Int
    /// 当前拥有任务句柄的共享解析数，含撤销写回但仍有等待者的旧任务。
    let flights: Int
    /// 在共享解析上注册的等待者总数，不包括还在独立准备快照的请求。
    let waiters: Int
}
