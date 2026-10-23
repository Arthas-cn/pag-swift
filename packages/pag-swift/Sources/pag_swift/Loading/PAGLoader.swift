import Foundation

/// 一次载入如何使用已解析文档和正在进行的共享解析。
public enum PAGLoadPolicy: Sendable, Hashable {
    /// 每次重新建立内容身份，再复用同版本缓存或共享解析。
    case useCache
    /// 撤销该来源/内容的旧写回资格并重新解析，不取消旧调用者。
    case reload
    /// 不读取、不写入缓存，也不与其他调用者共享解析任务。
    case uncached
}

/// 管理解析共享、独立取消与有界 LRU；IO、摘要和解码在并发执行域运行。
public actor PAGLoader {
    /// 进程内默认服务；需要独立预算或缓存生命周期时可自行初始化。
    public static let shared = PAGLoader(standardDefaults: ())
    /// 此服务内不可变的文件/解码限制。
    private let limits: PAGLoadLimits
    /// 后台 IO/解码边界及内部诊断，不向 public 暴露自定义执行器。
    private let operations: LoaderOperations
    /// 此 actor 独占的已解析文档 LRU。
    private var cache: ParsedFileCache
    /// 清理时换成新 UUID，避免整数代数回绕与旧结果再次匹配。
    private var generation = UUID()
    /// 活跃请求，包括正在独立准备快照的调用者；请求结束立即移除。
    private var requests: [UUID: LoadRequest] = [:]
    /// 持有全部共享解析任务，包含已撤销缓存资格但仍有旧等待者的 flight。
    private var flights: [UUID: LoadFlight] = [:]
    /// 只有当前允许加入的 flight 才出现在此表；旧任务不能覆盖新任务的键。
    private var joinable: [ParseKey: UUID] = [:]
    /// 生命周期累计标量，当前占用由 statistics 即时组装。
    private var counters = PAGCacheStatistics()
    /// 只保留最后 128 次终止报告，避免大量资源浏览产生无界历史。
    public private(set) var recentReports: [PAGLoadReport] = []

    /// 返回不可变计数与容量快照；不会暴露或改变缓存中的文档。
    public var statistics: PAGCacheStatistics {
        var value = counters
        value.evictions = cache.evictionCount
        value.cachedFiles = cache.count
        value.cachedBytes = cache.byteCount
        value.byteLimit = cache.byteLimit
        value.inFlightParses = flights.count
        return value
    }

    /// 创建独立服务；缓存预算可为零，负数抛 invalidArgument。
    public init(limits: PAGLoadLimits = .standard, cacheByteLimit: Int = 67_108_864) throws {
        try self.init(limits: limits, cacheByteLimit: cacheByteLimit, operations: LoaderOperations())
    }

    /// 仅用于已知合法的默认配置，避免 public shared 需要强制处理初始化错误。
    private init(standardDefaults: Void) {
        limits = .standard
        operations = LoaderOperations()
        cache = ParsedFileCache(byteLimit: 67_108_864)
    }

    /// 内部依赖注入入口；与 public 初始化执行相同预算检查。
    init(limits: PAGLoadLimits = .standard, cacheByteLimit: Int = 67_108_864,
         operations: LoaderOperations) throws {
        guard cacheByteLimit >= 0 else { throw PAGError.invalidArgument("cacheByteLimit") }
        self.limits = limits
        self.operations = operations
        cache = ParsedFileCache(byteLimit: cacheByteLimit)
    }

    /// 完整读取本地 PAG 并验证场景，不要求扩展名；取消抛 CancellationError。
    public func load(from url: URL, policy: PAGLoadPolicy = .useCache) async throws -> PAGFile {
        try await load(source: .file(url), policy: policy).file
    }

    /// 读取内存 PAG；只有完整摘要和解码约束相同才共享，失败不留下成功缓存。
    public func load(data: Data, policy: PAGLoadPolicy = .useCache) async throws -> PAGFile {
        try await load(source: .data(data), policy: policy).file
    }

    /// 稳定读取本地文件并返回本次阶段报告；错误仍抛出且写入 recentReports。
    public func loadWithReport(from url: URL, policy: PAGLoadPolicy = .useCache) async throws -> PAGLoadResult {
        try await load(source: .file(url), policy: policy)
    }

    /// 完整验证内存数据并返回本次阶段报告；没有文件读取阶段。
    public func loadWithReport(data: Data, policy: PAGLoadPolicy = .useCache) async throws -> PAGLoadResult {
        try await load(source: .data(data), policy: policy)
    }

    /// 清除留存并撤销当前请求/flight 的缓存资格；旧等待者及已返回文件保持有效。
    public func removeCachedFiles() {
        counters.invalidations += 1
        generation = UUID()
        cache.removeAll()
        joinable.removeAll()
        for id in requests.keys { requests[id]?.canCache = false }
    }

    /// 返回 actor 内一致的计费和任务所有权状态，用于内部验收与诊断。
    var diagnostics: LoaderDiagnostics {
        LoaderDiagnostics(cachedFiles: cache.count, cachedBytes: cache.byteCount,
                          flights: flights.count, waiters: flights.values.reduce(0) { $0 + $1.waiters.count })
    }

    /// 统一两个 public 入口；请求从准备前登记，保证清理能撤销迟到的准备结果。
    private func load(source: LoadSource, policy: PAGLoadPolicy) async throws -> PAGLoadResult {
        let requestID = UUID()
        let waiter = LoadWaiter()
        let sourceURL = source.requestURL
        if policy == .reload { counters.invalidations += 1 }
        if policy == .reload, let sourceURL { invalidate(sourceURL: sourceURL, key: nil, excluding: nil) }
        requests[requestID] = LoadRequest(sourceURL: sourceURL, waiter: waiter, canCache: policy != .uncached)
        defer {
            // 取消回调的 actor 消息可能还没到；这里同样负责摘除，且操作可重复。
            cancelRequest(requestID)
            requests.removeValue(forKey: requestID)
        }
        do {
            let file = try await withTaskCancellationHandler { () async throws -> PAGFile in
                try Task.checkCancellation()
                let snapshot: LoadSnapshot
                switch source {
                case .file(let url): snapshot = try await operations.read(url, limits)
                case .data(let data): snapshot = try await operations.prepare(data, limits)
                }
                try Task.checkCancellation()
                guard !waiter.isCancelled else { throw CancellationError() }
                let key = ParseKey(snapshot: snapshot, limits: limits)
                requests[requestID]?.key = key
                requests[requestID]?.readSeconds = snapshot.readSeconds
                requests[requestID]?.digestSeconds = snapshot.digestSeconds
                if policy == .reload, requests[requestID]?.canCache == true {
                    invalidate(sourceURL: sourceURL, key: key, excluding: requestID)
                }
                guard requests[requestID]?.canCache == true else {
                    // uncached 或准备期间被清理的请求只完成自身，不创建可写回的新代 flight。
                    requests[requestID]?.disposition = .bypassed
                    counters.parses += 1
                    let started = ContinuousClock.now
                    defer { requests[requestID]?.parseSeconds = loadElapsed(since: started) }
                    let file = try await operations.decode(snapshot, limits)
                    try Task.checkCancellation()
                    return file
                }
                if let file = cache.value(for: key) {
                    counters.hits += 1
                    requests[requestID]?.disposition = .hit
                    return file
                }
                counters.misses += 1
                joinOrStart(key: key, snapshot: snapshot, requestID: requestID, waiter: waiter)
                let waitStarted = ContinuousClock.now
                defer {
                    if requests[requestID]?.disposition == .shared {
                        requests[requestID]?.sharedWaitSeconds = loadElapsed(since: waitStarted)
                    }
                }
                let file = try await waiter.value()
                try Task.checkCancellation()
                return file
            } onCancel: {
                // 同步恢复本调用者，不等待共享解码或 actor 排队；随后移除共享任务中的登记。
                waiter.cancel()
                Task { await self.cancelRequest(requestID) }
            }
            let report = finishReport(requestID, policy: policy, status: .succeeded, error: nil)
            return PAGLoadResult(file: file, report: report)
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled || waiter.isCancelled
            if cancelled { counters.cancellations += 1 }
            else { counters.failures += 1 }
            _ = finishReport(requestID, policy: policy, status: cancelled ? .cancelled : .failed, error: error)
            throw error
        }
    }

    /// 加入当前 flight，或创建由 loader 显式持有和收尾的新任务。
    private func joinOrStart(key: ParseKey, snapshot: LoadSnapshot, requestID: UUID, waiter: LoadWaiter) {
        if let id = joinable[key], flights[id] != nil {
            counters.sharedRequests += 1
            requests[requestID]?.disposition = .shared
            flights[id]?.waiters[requestID] = waiter
            requests[requestID]?.flightID = id
            operations.observe(.joined(flights[id]?.waiters.count ?? 0))
            return
        }
        let flightID = UUID()
        counters.parses += 1
        requests[requestID]?.disposition = .miss
        let task = Task { [operations, limits] in
            let started = ContinuousClock.now
            let result: Result<PAGFile, any Error>
            do {
                let file = try await operations.decode(snapshot, limits)
                try Task.checkCancellation()
                result = .success(file)
            } catch { result = .failure(error) }
            self.finish(flightID, result: result, parseSeconds: loadElapsed(since: started))
        }
        flights[flightID] = LoadFlight(key: key, generation: generation, task: task, waiters: [requestID: waiter])
        joinable[key] = flightID
        requests[requestID]?.flightID = flightID
        operations.observe(.joined(1))
    }

    /// 处理一个 flight 的唯一完成，旧 ID 或已无等待者的迟到回调直接丢弃。
    private func finish(_ id: UUID, result: Result<PAGFile, any Error>, parseSeconds: Double) {
        guard let flight = flights.removeValue(forKey: id) else {
            // 最后等待者取消后，忽略取消的底层操作仍可能完成；不能重新创建缓存资格。
            operations.observe(.discarded)
            counters.discardedResults += 1
            return
        }
        let isCurrent = joinable[flight.key] == id
        if isCurrent { joinable.removeValue(forKey: flight.key) }
        var receivers = 0
        for (requestID, waiter) in flight.waiters {
            requests[requestID]?.parseSeconds = parseSeconds
            if waiter.resolve(result) { receivers += 1 }
        }
        // 取消可以在 actor 消息之前同步赢得门闩；没有接收者的结果不得回填缓存。
        if receivers > 0, isCurrent, flight.canCache, flight.generation == generation,
           case .success(let file) = result {
            cache.insert(file, for: flight.key)
        }
        operations.observe(.retired)
    }

    /// 在请求仍登记时固化报告；报告不保存原始输入、文件或可变解析任务。
    private func finishReport(_ id: UUID, policy: PAGLoadPolicy, status: PAGLoadStatus,
                              error: (any Error)?) -> PAGLoadReport {
        // 请求由本函数所在的 load defer 统一移除，因此整个完成路径必须仍能找到它。
        let request = requests[id]!
        let identity = request.key?.identity.digest.map { String(format: "%02x", $0) }.joined()
        let report = PAGLoadReport(id: id, startedAt: request.startedAt, sourcePath: request.sourceURL?.path,
            documentIdentity: identity, policy: String(describing: policy), status: status,
            cache: request.disposition, readSeconds: request.readSeconds, digestSeconds: request.digestSeconds,
            parseSeconds: request.parseSeconds, sharedWaitSeconds: request.sharedWaitSeconds,
            totalSeconds: loadElapsed(since: request.started), error: error.map { String(describing: $0) },
            statistics: statistics)
        recentReports.append(report)
        if recentReports.count > 128 { recentReports.removeFirst(recentReports.count - 128) }
        return report
    }

    /// 摘掉一个等待者；最后等待者离开才取消共享任务，并立即释放可加入索引。
    private func cancelRequest(_ id: UUID) {
        guard let request = requests[id], let flightID = request.flightID,
              flights[flightID] != nil else { return }
        flights[flightID]?.waiters.removeValue(forKey: id)
        guard flights[flightID]?.waiters.isEmpty == true,
              let flight = flights.removeValue(forKey: flightID) else { return }
        if joinable[flight.key] == flightID { joinable.removeValue(forKey: flight.key) }
        flight.task.cancel()
        operations.observe(.retired)
    }

    /// 撤销同来源或同内容的旧写回资格；请求与旧 flight 继续服务已有调用者。
    private func invalidate(sourceURL: URL?, key: ParseKey?, excluding excludedID: UUID?) {
        if let key { cache.remove(key) }
        for (id, request) in requests where id != excludedID {
            let matchesSource = sourceURL != nil && request.sourceURL == sourceURL
            let matchesContent = key != nil && request.key == key
            guard matchesSource || matchesContent else { continue }
            requests[id]?.canCache = false
            if let previousKey = request.key { cache.remove(previousKey) }
            if let flightID = request.flightID, let flight = flights[flightID] {
                flights[flightID]?.canCache = false
                if joinable[flight.key] == flightID { joinable.removeValue(forKey: flight.key) }
            }
        }
    }
}

/// Public 两种载入来源的内部表示；只用于当前请求，不形成无界来源历史表。
private enum LoadSource: Sendable {
    /// 本次要重新读取的本地 URL。
    case file(URL)
    /// 调用者提供的不可变字节值。
    case data(Data)

    /// 用于准备期间撤销的标准化请求 URL；内存内容需摘要准备后才能识别。
    var requestURL: URL? {
        if case .file(let url) = self { return url.standardizedFileURL }
        return nil
    }
}

/// 一个调用者的暂存状态，生命周期严格从 load 进入到退出。
private struct LoadRequest {
    /// 此次调用登记时间，供人类日志关联。
    let startedAt = Date()
    /// 此次调用单调起点，用于总耗时。
    let started = ContinuousClock.now
    /// 标准化请求 URL；内存请求为 nil。
    let sourceURL: URL?
    /// 独立取消/完成门闩，跨线程状态由自身 Mutex 保护。
    let waiter: LoadWaiter
    /// 清理/reload 可撤销的缓存参与资格。
    var canCache: Bool
    /// 摘要准备完成后才设置的解析键。
    var key: ParseKey?
    /// 已登记的共享解析 ID；独立或准备中的请求为 nil。
    var flightID: UUID?
    /// 摘要完成后才可确定缓存路径。
    var disposition: PAGCacheDisposition = .unavailable
    /// 稳定读取耗时；内存输入或准备失败时为 nil。
    var readSeconds: Double?
    /// 完整摘要耗时；尚未完成时为 nil。
    var digestSeconds: Double?
    /// 实际解析耗时；命中或取消时解析尚未返回则为 nil。
    var parseSeconds: Double?
    /// 加入共享解析的等待耗时；其它路径为 nil。
    var sharedWaitSeconds: Double?
}

/// Loader 拥有的共享任务，状态仅在 loader actor 内修改。
private struct LoadFlight {
    /// 完整内容、限制和解码实现的解析键。
    let key: ParseKey
    /// 创建时的缓存代数，清理后不再允许写回。
    let generation: UUID
    /// 最后等待者离开时必须取消的任务句柄。
    let task: Task<Void, Never>
    /// 独立调用者及其一次性完成门闩。
    var waiters: [UUID: LoadWaiter]
    /// reload 可单独撤销当前内容的缓存写回，不必取消旧等待者。
    var canCache = true
}
