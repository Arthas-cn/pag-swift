import Foundation

/// 每场景的快速帧缓存与有限请求队列；同步解码由独立 worker 执行，不占用本 actor。
actor AnimatedImageFrameStore {
    /// 解码仅在专用串行队列执行，播放采样不进入该队列等待。
    private let decoder = AnimatedFrameDecoder()
    /// 缓存及在途三份画布共用的预算，不包含宿主 decoder 自有缓存。
    private let maximumBytes: Int
    /// 最近使用的完整帧在末尾；实时路径最多 32 帧、16 种素材。
    private var entries: [AnimatedFrameEntry] = []
    /// 每个实例最近实际选中的帧身份；最多 64 项，不额外持有像素。
    private var selections: [AnimatedFrameSelection] = []
    /// 每实例只保留最新目标；最多 16 项，没有独立计时器或自动序列预解。
    private var pending: [AnimatedFrameRequest] = []
    /// 当前唯一同步调用对应的句柄，取消后仍须等真实返回才释放工作名额。
    private var work: Task<AnimatedFrameDecodeResult, Never>?
    /// 当前工作身份与预算；只有匹配的完成才能发布缓存。
    private var current: AnimatedFrameRequest?
    /// 已安装素材集合；nil 表示只用于精确帧计划，未收到播放场景限制。
    private var allowed: Set<DocumentIdentity>?
    /// 宿主失败只影响对应素材，诊断累计计数不因缓存淘汰丢失。
    private var hostFailures = 0
    /// 最近宿主可读错误，尚无失败为 nil。
    private var lastHostFailure: String?
    /// ImageIO 终态错误等待下一次对应素材采样消费，最多 16 项。
    private var failures: [DocumentIdentity: PAGError] = [:]

    /// 创建有限缓存；无效预算在实际请求时抛资源错误。
    init(maximumBytes: Int = 64 * 1024 * 1024) { self.maximumBytes = maximumBytes }

    /// worker 只弱引用本 owner，释放时取消当前工作，不等待不合作同步调用。
    deinit { work?.cancel() }

    /// 只读缓存、在途预留及排队数量，绝不等待后台解码完成。
    var diagnostics: AnimatedFrameDiagnostics {
        AnimatedFrameDiagnostics(retainedBytes: retainedBytes(), byteLimit: maximumBytes,
            decodingBytes: current?.reservation ?? 0, pendingFrames: pending.count,
            decodingFrames: current == nil ? 0 : 1, hostFailures: hostFailures, lastHostFailure: lastHostFailure)
    }

    /// 实时新帧计划限制允许素材并清理旧队列；暂停不再启动预取，已有一项可自然结束。
    func retainMaterials(_ identities: Set<DocumentIdentity>, isPlaying: Bool) throws {
        try Task.checkCancellation()
        allowed = identities
        entries.removeAll { !identities.contains($0.material) }
        selections.removeAll { !identities.contains($0.material) }
        pending.removeAll { !isPlaying || !identities.contains($0.material) }
        failures = failures.filter { identities.contains($0.key) }
        if let current, !identities.contains(current.material) { work?.cancel() }
    }

    /// 精确计划等待目标帧，供离线取样和像素验证；实时显示必须使用 availableFrame。
    func frame(for image: PAGImage, at time: PAGTime) async throws -> PAGImage {
        try Task.checkCancellation()
        guard let animation = image.animation else { return image }
        let index = animation.frameIndex(at: time)
        while true {
            if let hit = cached(animation.identity, index: index) { return hit }
            if let work {
                _ = await work.value
                try Task.checkCancellation()
                continue // await 后缓存/工作可能变化，重新验证，不能并发启动第二项解码。
            }
            let request = try makeRequest(image, index: index, scope: .material(animation.identity), exact: true)
            let task = start(request)
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            switch result {
            case .frame(let output): return output
            case .unavailable, .hostFailure: return latest(for: image)
            case .failure(let error): throw error
            case .cancelled: throw CancellationError()
            }
        }
    }

    /// 不等待解码：返回本实例最近帧或首帧；只请求当前缺失帧或紧邻下一帧。
    func availableFrame(for image: PAGImage, at time: PAGTime, instance: PAGLayerID? = nil,
                        isPlaying: Bool) throws -> PAGImage {
        try Task.checkCancellation()
        guard let animation = image.animation else { return image }
        guard allowed?.contains(animation.identity) != false else { return PAGImage(storage: image.storage) }
        if let failure = failures.removeValue(forKey: animation.identity) { throw failure }
        let scope = instance.map(AnimatedFrameScope.layer) ?? .material(animation.identity)
        let index = animation.frameIndex(at: time)
        let selected = index == 0 ? PAGImage(storage: image.storage) : cached(animation.identity, index: index)
        if let selected {
            selections.removeAll { $0.scope == scope }
            if selections.count >= 64 { selections.removeFirst() }
            selections.append(AnimatedFrameSelection(scope: scope, material: animation.identity, frame: selected.storage.identity))
        }
        if isPlaying {
            let requested: Int?
            if selected == nil { requested = index }
            else if let count = animation.playCount,
                    time.microseconds / animation.durationMicroseconds >= count - 1,
                    index == animation.ends.count - 1 { requested = nil }
            else { requested = (index + 1) % animation.ends.count }
            // 首帧已经随素材准备，不额外预解第零帧；每个实例的旧目标由最新进度取代。
            pending.removeAll { $0.scope == scope }
            if let requested, requested != 0,
               !entries.contains(where: { $0.material == animation.identity && $0.index == requested }),
               !(current?.material == animation.identity && current?.index == requested) {
                let request = try makeRequest(image, index: requested, scope: scope, exact: false)
                if pending.count >= 16 { pending.removeFirst() }
                pending.append(request)
            }
            startPendingIfIdle()
        } else { pending.removeAll() }
        if let selected { return selected }
        if let previous = selections.last(where: { $0.scope == scope && $0.material == animation.identity }),
           let retained = entries.last(where: { $0.image.storage.identity == previous.frame }) {
            return retained.image
        }
        return PAGImage(storage: image.storage)
    }

    /// 当前 owner 保活的 RGBA 字节；首帧属于素材本身，旧计划持有的输入另计。
    func retainedBytes() -> Int { entries.reduce(0) { $0 + $1.image.storage.pixels.count } }

    /// 测试可等待已经存在的工作完成；不产生新请求，也不把播放改成等待模式。
    func waitForCurrentWork() async { _ = await work?.value }

    /// 命中后移至 LRU 末尾，不改变其它实例的最近显示记录。
    private func cached(_ material: DocumentIdentity, index: Int) -> PAGImage? {
        guard let position = entries.firstIndex(where: { $0.material == material && $0.index == index }) else { return nil }
        let entry = entries.remove(at: position)
        entries.append(entry)
        return entry.image
    }

    /// 验证三份画布工作预算后建立请求；只传不可变素材，不捕获播放器或显示表面。
    private func makeRequest(_ image: PAGImage, index: Int, scope: AnimatedFrameScope,
                             exact: Bool) throws -> AnimatedFrameRequest {
        guard let animation = image.animation, maximumBytes > 0,
              let width = Int(exactly: animation.size.width), let height = Int(exactly: animation.size.height),
              width > 0, height > 0, width <= maximumBytes / 12 / height else {
            throw PAGError.resourceLimitExceeded("maximumAnimatedFrameBytes")
        }
        return AnimatedFrameRequest(id: UUID(), image: image, material: animation.identity,
            index: index, scope: scope, reservation: width * height * 12, exact: exact)
    }

    /// 只由新的显示采样启动下一项；暂停/离屏后不继续把排队素材轮流解完。
    private func startPendingIfIdle() {
        guard work == nil else { return }
        while !pending.isEmpty {
            let request = pending.removeFirst()
            if allowed?.contains(request.material) == false { continue }
            if entries.contains(where: { $0.material == request.material && $0.index == request.index }) { continue }
            _ = start(request)
            return
        }
    }

    /// 先淘汰到能容纳三份画布，再启动唯一 worker；全程不在采样 actor 做同步解码。
    private func start(_ request: AnimatedFrameRequest) -> Task<AnimatedFrameDecodeResult, Never> {
        precondition(work == nil)
        let countLimit = request.exact ? 16 : 32
        while !entries.isEmpty && (retainedBytes() > maximumBytes - request.reservation ||
            entries.count >= countLimit || Set(entries.map(\.material)).union([request.material]).count > 16) {
            entries.removeFirst()
        }
        current = request
        // 必须不继承本 actor 的执行上下文；仅弱回调，才能在同步宿主尚未返回时释放 owner。
        // 任务句柄由本 owner 唯一持有，deinit 取消；真实工作名额直到 finish 才归还。
        let task = Task.detached(priority: .userInitiated) { [weak self, decoder, maximumBytes] in
            let result = await decoder.decode(request.image, index: request.index, maximumBytes: maximumBytes)
            await self?.finish(result, request: request)
            return result
        }
        work = task
        return task
    }

    /// 完成只发布仍被当前场景允许的素材；预取结果不更新任何实例已显示的帧身份。
    private func finish(_ result: AnimatedFrameDecodeResult, request: AnimatedFrameRequest) {
        guard current?.id == request.id else { return }
        work = nil
        current = nil
        guard allowed?.contains(request.material) != false else { return }
        switch result {
        case .frame(let image):
            entries.removeAll { $0.material == request.material && (request.exact || $0.index == request.index) }
            entries.append(AnimatedFrameEntry(material: request.material, index: request.index, image: image))
        case .hostFailure(let reason):
            hostFailures += 1
            lastHostFailure = reason
        case .failure(let error):
            if !request.exact {
                if failures.count >= 16, let oldest = failures.keys.first { failures[oldest] = nil }
                failures[request.material] = error
            }
        case .unavailable, .cancelled: break // 不发布部分帧，也不因一次缺帧递归重试。
        }
    }

    /// 精确入口的缺帧沿用同素材最近完成帧；不同素材只能回退自己的首帧。
    private func latest(for image: PAGImage) -> PAGImage {
        entries.last(where: { $0.material == image.animation?.identity })?.image ?? PAGImage(storage: image.storage)
    }
}

/// 动图 owner 的缓存及有限后台工作摘要，不混入宿主下载缓存或 GPU 纹理计费。
struct AnimatedFrameDiagnostics: Sendable {
    /// 当前缓存帧的 RGBA 字节。
    let retainedBytes: Int
    /// 缓存加三份在途画布共用的上限。
    let byteLimit: Int
    /// 当前一项解码的保守三画布预留；闲置为零。
    let decodingBytes: Int
    /// 尚未启动的合并请求，范围 0...16。
    let pendingFrames: Int
    /// 当前同步 worker 数，范围 0...1。
    let decodingFrames: Int
    /// 宿主错误累计次数。
    let hostFailures: Int
    /// 最近宿主错误，尚无失败为 nil。
    let lastHostFailure: String?
}
