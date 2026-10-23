import Foundation

/// 仅由 PAGPlayer actor 修改的动态内容会话；宿主任务只持有独立门闩与只读输入。
struct PlayerContentState: Sendable {
    /// 取消全会话或切换文档时替换，用于拒绝准备完成后的迟到提交。
    var session = UUID()
    /// 当前请求预算，默认四并发和五秒等待。
    var options = PAGContentOptions.standard
    /// URL 获取完全由宿主实现；nil 时明确拒绝 imageURL。
    var loadImage: (@Sendable (URL) async throws -> PAGImage)?
    /// 每 tag 最新请求版本，已完成版本也保留供准备提交验证。
    var versions: [String: UUID] = [:]
    /// 尚未返回 provider 结果的请求，数量受 maximumPendingRequests 约束。
    var jobs: [String: ContentJob] = [:]
    /// FIFO 待解析 tag，连续更新同 tag 时移除旧位置。
    var pending: [String] = []
    /// 仍等待门闩的控制任务；真实未退出宿主调用另由 capacity 计数。
    var running: [UUID: Task<Void, Never>] = [:]
    /// 待安装的已解析内容，同 tag 只保留最新一份。
    var ready: [String: ContentReady] = [:]
    /// 串行准备队列，防止不同 tag 从旧合成各自准备导致编辑互相覆盖。
    var readyOrder: [String] = []
    /// 唯一准备安装任务；取消时同步撤销请求身份，不等它退出才撤销。
    var commitTask: Task<Void, Never>?
    /// 正在准备的内容身份，nil 表示没有提交中的内容。
    var committing: ContentRequestToken?
    /// 不合作宿主工作的硬配额，跨内容会话继续生效。
    let capacity = ContentProviderCapacity()
    /// 最近 256 条请求与安装诊断，worker 可安全追加迟到结果。
    let log = ContentEventLog()

    /// 当前版本与会话都相同时才允许把异步产物安装到场景。
    func accepts(_ token: ContentRequestToken) -> Bool {
        token.session == session && versions[token.tag] == token.version
    }

    /// 同步撤销全部工作并释放宿主闭包；已完成的画面保留在播放器中。
    mutating func cancel() {
        var tokens = Dictionary(jobs.values.map { ($0.token.version, $0.token) }, uniquingKeysWith: { a, _ in a })
        for item in ready.values { tokens[item.token.version] = item.token }
        if let committing { tokens[committing.version] = committing }
        for token in tokens.values { log.record(token, .cancelled) }
        for job in jobs.values { job.gate.resolve(.failure(CancellationError())) }
        for task in running.values { task.cancel() }
        commitTask?.cancel()
        session = UUID()
        versions.removeAll()
        jobs.removeAll()
        pending.removeAll()
        running.removeAll()
        ready.removeAll()
        readyOrder.removeAll()
        commitTask = nil
        committing = nil
        loadImage = nil
    }
}

/// 一次异步供给请求；只由控制 actor 建立与移除。
struct ContentJob: Sendable {
    /// 完整文档、会话和版本身份。
    let token: ContentRequestToken
    /// 已发现的源槽，避免后台重新扫描文档。
    let slot: PAGContentSlot
    /// 宿主只负责此槽使用何种素材。
    let provider: PAGContentProvider
    /// 取消时可同步结束等待，不要求 provider 合作。
    let gate: ContentResolutionGate
}

/// 串行安装队列中的不可变内容；同 tag 新版本可以覆盖旧排队内容。
struct ContentReady: Sendable {
    /// 准备前后均需核对的请求身份。
    let token: ContentRequestToken
    /// 已完成 URL 解析的类型化素材或立即占位。
    let content: DynamicContent
    /// 占位安装与最终替换在日志中分开。
    let isPlaceholder: Bool
}
