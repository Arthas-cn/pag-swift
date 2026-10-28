import Foundation

/// 播放器的业务源槽入口；请求队列与帧调度分离，替换仍复用同一场景准备和 Metal 通路。
extension PAGPlayer {
    /// 当前安装合成的真实可编辑源槽；无合成返回空，查询复杂度 O(n log n)。
    public var contentSlots: [PAGContentSlot] { contentComposition?.contentSlots ?? [] }

    /// 最近 256 条内容事件的不可变副本；安装成功不等于显示完成，复杂度 O(256)。
    public var contentEvents: [PAGContentEvent] { contentState.log.snapshot }

    /// 订阅未来内容事件，每个消费者最多缓冲 256 条；取消或播放器释放时结束。
    public func contentUpdates() -> AsyncStream<PAGContentEvent> { contentState.log.updates() }

    /// 为当前合成每个源槽请求一次内容；不等待宿主完成，失败回退不会停止主播放。
    /// 无合成或预算不足在开始前抛错；新 provider 撤销上一会话，已安装的内容保持不变。
    public func setContentProvider(_ provider: @escaping PAGContentProvider,
        options: PAGContentOptions = .standard,
        loadImageFromURL: (@Sendable (URL) async throws -> PAGImage)? = nil) throws {
        try Task.checkCancellation()
        guard contentComposition != nil else { throw PAGError.missingComposition }
        let slots = contentSlots
        guard slots.count <= options.maximumPendingRequests else {
            throw PAGError.resourceLimitExceeded("pendingContentRequests")
        }
        cancelContentRequests()
        contentState.options = options
        contentState.loadImage = loadImageFromURL
        for slot in slots { enqueueContentRequest(slot, provider: provider) }
        startContentRequests()
    }

    /// 按目录 tag 更新、隐藏或恢复一个槽；类型/非法 tag 同步抛错，准备失败写 contentEvents。
    /// imageURL 使用 setContentProvider 注册的宿主回调，其它已就绪内容不占宿主调用配额。
    public func updateContent(_ content: DynamicContent, forTag tag: String) throws {
        try Task.checkCancellation()
        let slot = try contentSlot(tag)
        try validateContent(content, for: slot)
        try checkContentCapacity(for: tag)
        if case .imageURL = content {
            try resolveContent(forTag: tag) { _ in content }
            return
        }
        cancelContentRequest(tag)
        let token = makeContentToken(tag)
        contentState.versions[tag] = token.version
        contentState.log.record(token, .requested, content: content)
        enqueueContentCommit(ContentReady(token: token, content: content, isPlaceholder: false))
    }

    /// 撤销同 tag 旧请求，先安装显式占位，再异步取得新内容；失败/超时保留已安装占位。
    /// 默认 unchanged 保留当前内容。占位须已就绪，不能再递归请求 URL。
    public func resolveContent(forTag tag: String, placeholder: DynamicContent = .unchanged,
                               using provider: @escaping PAGContentProvider) throws {
        try Task.checkCancellation()
        let slot = try contentSlot(tag)
        try validateContent(placeholder, for: slot)
        if case .imageURL = placeholder { throw PAGError.invalidArgument("contentPlaceholderURL") }
        try checkContentCapacity(for: tag)
        cancelContentRequest(tag)
        let token = enqueueContentRequest(slot, provider: provider)
        if case .unchanged = placeholder { /* 保留当前画面无需额外场景准备。 */ }
        else { enqueueContentCommit(ContentReady(token: token, content: placeholder, isPlaceholder: true)) }
        startContentRequests()
    }

    /// 撤销所有在途请求、占位和准备提交，保留已安装内容；页面退出时可直接调用。
    public func cancelContentRequests() { contentState.cancel() }

    /// 调用错误在任何编辑或请求撤销前验证，避免坏输入破坏仍有效的工作。
    private func contentSlot(_ tag: String) throws -> PAGContentSlot {
        guard contentComposition != nil else { throw PAGError.missingComposition }
        guard let slot = contentSlots.first(where: { $0.tag == tag }) else {
            throw PAGError.invalidArgument("dynamicTag")
        }
        return slot
    }

    /// provider 等待和场景安装一起计入待处理预算，不能通过大量就绪图片绕过队列上限。
    private func checkContentCapacity(for tag: String) throws {
        var tags = Set(contentState.jobs.keys).union(contentState.ready.keys)
        if let token = contentState.committing { tags.insert(token.tag) }
        guard tags.contains(tag) || tags.count < contentState.options.maximumPendingRequests else {
            throw PAGError.resourceLimitExceeded("pendingContentRequests")
        }
    }

    /// 只做内容类别和回调存在性检查；字体、框和动态媒体的完整验证留给场景准备。
    private func validateContent(_ content: DynamicContent, for slot: PAGContentSlot) throws {
        if case .image(let image, let options) = content { _ = try options.image(from: image) }
        switch content {
        case .text:
            guard slot.kind == .text else { throw PAGError.invalidArgument("dynamicContentKind") }
        case .image, .imageURL:
            guard slot.kind == .image else { throw PAGError.invalidArgument("dynamicContentKind") }
            if case .imageURL = content, contentState.loadImage == nil {
                throw PAGError.invalidArgument("loadImageFromURL")
            }
        case .unchanged, .hidden, .original: break
        }
    }

    /// 记录完整文档摘要；只在入队时计算字符串，不进入逐帧路径。
    private func makeContentToken(_ tag: String) -> ContentRequestToken {
        let document = contentComposition?.storage.identity.digest.map { String(format: "%02x", $0) }.joined() ?? ""
        return ContentRequestToken(document: document, session: contentState.session,
                                   version: UUID(), tag: tag, started: .now)
    }

    /// 新请求入队但暂不启动，允许全部源槽一次验证预算后再批量调度。
    @discardableResult private func enqueueContentRequest(_ slot: PAGContentSlot,
        provider: @escaping PAGContentProvider) -> ContentRequestToken {
        let token = makeContentToken(slot.tag)
        contentState.versions[slot.tag] = token.version
        contentState.jobs[slot.tag] = ContentJob(token: token, slot: slot, provider: provider,
                                               gate: ContentResolutionGate())
        contentState.pending.append(slot.tag)
        contentState.log.record(token, .requested)
        return token
    }

    /// 同槽新内容撤销旧请求；门闩先结束等待，不等不合作宿主返回。
    private func cancelContentRequest(_ tag: String) {
        var cancelled: [UUID: (ContentRequestToken, DynamicContent?)] = [:]
        if let job = contentState.jobs.removeValue(forKey: tag) {
            job.gate.resolve(.failure(CancellationError()))
            contentState.running[job.token.version]?.cancel()
            cancelled[job.token.version] = (job.token, nil)
        }
        if let ready = contentState.ready.removeValue(forKey: tag) {
            cancelled[ready.token.version] = (ready.token, ready.content)
        }
        if let committing = contentState.committing, committing.tag == tag,
           cancelled[committing.version] == nil {
            cancelled[committing.version] = (committing, nil)
        }
        // 就绪内容也可能在安装前被替换；按版本去重，不能只给仍在等待 provider 的请求记取消。
        for (token, content) in cancelled.values { contentState.log.record(token, .cancelled, content: content) }
        contentState.pending.removeAll { $0 == tag }
        contentState.readyOrder.removeAll { $0 == tag }
        contentState.versions[tag] = nil
    }

    /// 保持有限等待任务数；后台任务等待期间只弱引用播放器。
    private func startContentRequests() {
        while contentState.running.count < contentState.options.maximumConcurrentRequests,
              !contentState.pending.isEmpty {
            let tag = contentState.pending.removeFirst()
            guard let job = contentState.jobs[tag] else { continue }
            let options = contentState.options, loadImage = contentState.loadImage
            let capacity = contentState.capacity, log = contentState.log
            let task = Task { [weak self] in
                let result = await ContentResolution.run(slot: job.slot, provider: job.provider,
                    loadImage: loadImage, token: job.token, timeout: options.timeout,
                    gate: job.gate, capacity: capacity, log: log)
                await self?.finishContentRequest(job.token, result: result)
            }
            contentState.running[job.token.version] = task
        }
    }

    /// 返回结果必须匹配最新版本；失败只写内容诊断，不调用播放器主失败通路。
    private func finishContentRequest(_ token: ContentRequestToken, result: Result<DynamicContent, any Error>) {
        contentState.running[token.version] = nil
        defer { startContentRequests() }
        guard contentState.accepts(token) else { return }
        contentState.jobs[token.tag] = nil
        switch result {
        case .success(let content):
            enqueueContentCommit(ContentReady(token: token, content: content, isPlaceholder: false))
        case .failure(let error):
            let status: PAGContentEventStatus = error is ContentResolutionError ? .timedOut :
                (error is CancellationError ? .cancelled : .failed)
            contentState.log.record(token, status, detail: String(describing: error))
        }
    }

    /// 同 tag 合并最新安装，跨 tag 按完成顺序串行消费以保留其它已安装编辑。
    private func enqueueContentCommit(_ ready: ContentReady) {
        if contentState.ready[ready.token.tag] == nil { contentState.readyOrder.append(ready.token.tag) }
        contentState.ready[ready.token.tag] = ready
        guard contentState.commitTask == nil else { return }
        let session = contentState.session
        contentState.commitTask = Task { [weak self] in
            await self?.commitContentQueue(session: session)
        }
    }

    /// 每次从最新已安装合成复制候选；准备失败不污染后续 tag 的基础快照。
    private func commitContentQueue(session: UUID) async {
        defer {
            // 旧任务退出时不能清掉新会话刚创建的提交任务。
            if contentState.session == session {
                contentState.commitTask = nil
                contentState.committing = nil
            }
        }
        while contentState.session == session, !Task.isCancelled, !contentState.readyOrder.isEmpty {
            let tag = contentState.readyOrder.removeFirst()
            guard let ready = contentState.ready.removeValue(forKey: tag),
                  contentState.accepts(ready.token), var composition = contentComposition else { continue }
            contentState.committing = ready.token
            do {
                if case .unchanged = ready.content {
                    contentState.log.record(ready.token, .unchanged, content: ready.content)
                    continue
                }
                try await composition.apply(ready.content, forTag: tag)
                try await replaceContentComposition(composition, token: ready.token)
                contentState.log.record(ready.token, ready.isPlaceholder ? .placeholder : .applied, content: ready.content)
            } catch {
                let status: PAGContentEventStatus = error is CancellationError ? .discarded : .failed
                contentState.log.record(ready.token, status, detail: String(describing: error), content: ready.content)
            }
            contentState.committing = nil
        }
    }
}
