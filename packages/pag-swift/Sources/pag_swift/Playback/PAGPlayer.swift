import Foundation

/// 统一播放控制actor，串行接受控制并发布快照；求值和GPU工作留在后台所有者。
public actor PAGPlayer {
    /// 业务内容请求由本 actor 串行管理；后台 provider 不保活播放器。
    var contentState = PlayerContentState()
    /// 独立会话诊断对象允许系统回调只保存小值，不反向保活播放器。
    private var diagnosticSession: PlaybackDiagnosticSession?
    /// 当前安装会话的阶段、资源与实际呈现证据；未安装时返回 nil。
    public var diagnostics: PAGPlaybackDiagnostics? { diagnosticSession?.snapshot }
    /// 供内容入口建立候选快照；没有已安装场景时为 nil。
    var contentComposition: PAGComposition? { scene?.composition }
    /// 完整场景资源；nil 表示没有可求值的合成。
    var scene: PreparedScene?
    /// 纯值时间状态机，不在其中启动任务。
    var timeline = PlaybackTimeline()
    /// 最后有效提交的量化时间；换合成代数后重新等待首帧。
    private var presentedTime: PAGTime?
    /// 空内容尚需清理当前目标；成功清屏后归零，换显示代数或再次nil安装时重新置位。
    var needsClear = true
    /// 最近提交暂时拿不到drawable；即使ready/paused也需真实刷新恢复，成功呈现后停止重试。
    private var retriesPresentation = false
    /// 对外可观察的合成提交代数，不回绕。
    private var revision: UInt64 = 0
    /// 显示缩放设置，换文档时保留。
    private var scaleMode: PAGScaleMode = .aspectFit
    /// 时间控制撤销的当前身份。
    private var playbackEpoch = UUID()
    /// 显示生命周期撤销的当前身份。
    var targetEpoch = UUID()
    /// 最新安装请求的身份；准备期间其他控制仍可以运行。
    private var preparationID: UUID?
    /// 当前安装准备的可取消句柄；更新安装时立即取消旧 CPU 工作，迟到结果仍由身份拒绝。
    private var preparationTask: Task<PreparedScene, any Error>?
    /// 唯一活动后台任务；取消后也等待其退出才开始下一份工作。
    private var active: ActivePlaybackFrame?
    /// 只保留最新的未开始请求，积压不产生无界队列。
    private var pending: QueuedPlaybackFrame?
    /// 提交 owner 与控制命令共享的同步许可门。
    private let gate = PlaybackSubmissionGate()
    /// 当前绑定的真实提交边界；nil表示没有显示目标，内部测试可注入受控提交器。
    var submitter: (any PlaybackSubmitting)?
    /// 播放器生命周期内固定的绑定拥有者身份。
    let playerID = UUID()
    /// 最近一次绑定控制请求，迟到预约不能覆盖新指令。
    var bindingTransaction = UUID()
    /// 最新接受的原生宿主意图；nil表示最近绑定由独立公开API管理。
    var hostRequest: DisplayHostToken?
    /// 实际已绑定表面的宿主身份，与尚在准备的新请求分开，便于只清理旧目标。
    var boundHost: DisplayHostToken?
    /// 当前强持有的独立显示表面；nil表示未绑定。
    var surface: PAGSurface?
    /// 已安装的独占预约，小值通道不反向保活播放器。
    var displayBinding: DisplayBinding?
    /// 唯一显示消息消费任务，display tick不逐次创建Task。
    var displayTask: Task<Void, Never>?
    /// 尚未完成的表面预约；新attach/detach同步取消旧worker。
    var surfacePreparation: (surface: PAGSurface, task: Task<DisplayBinding, any Error>)?
    /// 单调时钟、场景准备和内部诊断注入。
    let operations: PlaybackOperations
    /// 每位消费者独立的 bufferingNewest(1) 生产端。
    private var observers: [UUID: AsyncStream<PAGPlaybackSnapshot>.Continuation] = [:]

    /// 创建无合成、无显示目标的播放器；默认留边缩放，总共播放一次。
    public init() {
        submitter = nil
        operations = PlaybackOperations()
    }

    /// 内部测试注入真实协议边界与可控时钟，不创建平台刷新计时器。
    init(submitter: any PlaybackSubmitting, operations: PlaybackOperations = PlaybackOperations()) {
        self.submitter = submitter
        self.operations = operations
    }

    /// 所有者释放时撤销许可、取消工作并结束订阅；后台任务仅弱引用控制器。
    deinit {
        contentState.cancel()
        contentState.log.finishUpdates()
        gate.revoke()
        displayTask?.cancel()
        surfacePreparation?.task.cancel()
        displayBinding?.cancel()
        if let surface, let displayBinding { Task { await surface.release(displayBinding) } }
        preparationTask?.cancel()
        active?.task.cancel()
        active?.frame.waiter?.cancel()
        pending?.waiter?.cancel()
        for observer in observers.values { observer.finish() }
    }

    /// 当前一致快照，无需等待求值或提交。
    public var snapshot: PAGPlaybackSnapshot {
        PAGPlaybackSnapshot(state: timeline.state, position: timeline.position, presentedTime: presentedTime,
                            duration: timeline.duration, completedIterations: timeline.completedIterations,
                            repeatCount: timeline.repeatCount, revision: revision, failure: timeline.failure)
    }

    /// 当前是否需要平台刷新，包括播放推进和暂不可呈现的重试；不依赖UI状态镜像。
    var requiresDisplayRefresh: Bool {
        let awaitingPresentation = ((scene == nil && needsClear) || retriesPresentation)
            && timeline.failure == nil && timeline.target != .detached
        return timeline.state == .playing || timeline.state == .suspended || awaitingPresentation
    }

    /// 新订阅先收到当前值；消费者取消后异步移除生产端，不积累历史帧。
    public func snapshots() -> AsyncStream<PAGPlaybackSnapshot> {
        let id = UUID()
        let pair = AsyncStream.makeStream(of: PAGPlaybackSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        observers[id] = pair.continuation
        pair.continuation.yield(snapshot)
        operations.observe(.subscriptionCount(observers.count))
        return pair.stream
    }

    /// 后台准备后原子安装；nil撤销内容并安排透明清屏，隐藏时延后，失败/取消不安装部分场景。
    public func setComposition(_ composition: PAGComposition?) async throws {
        let started = ContinuousClock.now
        try Task.checkCancellation()
        cancelContentRequests()
        let id = beginPreparation()
        defer { finishPreparation(id) }
        var prepared: PreparedScene?
        if let composition { prepared = try await prepare(composition, reusing: scene) }
        else { prepared = nil }
        try Task.checkCancellation()
        guard preparationID == id else { throw CancellationError() }
        let next = try nextRevision()
        try timeline.install(duration: composition?.duration)
        revokeWork()
        playbackEpoch = UUID()
        // 准备期间可能又收到针对旧场景的 provider，安装新文档前也要撤销。
        cancelContentRequests()
        prepared?.marqueeClock?.reset()
        prepared?.placeholderClock?.reset()
        prepared?.imageAnimationTimeline.install(at: .zero, reset: true)
        scene = prepared
        diagnosticSession = PlaybackDiagnosticSession(playerID: playerID, document: composition?.storage.identity)
        diagnosticSession?.record(.prepared, seconds: loadElapsed(since: started))
        needsClear = prepared == nil
        revision = next
        presentedTime = nil
        enqueueCurrent()
        publish()
    }

    /// 完整准备同文档编辑后保留当前时间与意图；跨文档或准备失败不修改原状态。
    public func replaceComposition(_ composition: PAGComposition) async throws {
        try Task.checkCancellation()
        cancelContentRequests()
        try await replacePreparedComposition(composition, contentToken: nil)
    }

    /// 动态内容准备复用原编辑安装通路，提交前再次核对会话和单槽版本。
    func replaceContentComposition(_ composition: PAGComposition, token: ContentRequestToken) async throws {
        guard contentState.accepts(token) else { throw CancellationError() }
        try await replacePreparedComposition(composition, contentToken: token)
    }

    /// 完整准备后保留播放时间；可选 token 只授予当前业务请求提交资格。
    private func replacePreparedComposition(_ composition: PAGComposition,
                                            contentToken: ContentRequestToken?) async throws {
        let started = ContinuousClock.now
        try Task.checkCancellation()
        guard let previous = scene else { throw PAGError.missingComposition }
        guard composition.storage.identity == previous.composition.storage.identity else {
            throw PAGError.invalidArgument("compositionDocument")
        }
        let id = beginPreparation()
        defer { finishPreparation(id) }
        var prepared = try await prepare(composition, reusing: previous)
        try Task.checkCancellation()
        guard preparationID == id else { throw CancellationError() }
        if let contentToken {
            guard contentState.accepts(contentToken) else { throw CancellationError() }
        } else { cancelContentRequests() }
        let next = try nextRevision()
        let now = operations.now()
        timeline.advance(to: now)
        try timeline.replace(duration: composition.duration, at: now)
        prepared.imageAnimationTimeline.install(at: PAGTime(microseconds: Int64(min(timeline.imageElapsed, UInt64(Int64.max)))))
        revokeWork()
        playbackEpoch = UUID()
        scene = prepared
        diagnosticSession?.record(.prepared, seconds: loadElapsed(since: started))
        needsClear = false
        revision = next
        presentedTime = nil
        enqueueCurrent()
        publish()
    }

    /// 开始或继续播放，重复调用幂等；无合成/目标或主工作失败时保持原状态。
    public func play() async throws {
        try Task.checkCancellation()
        let restarting = timeline.state == .finished
        guard try timeline.play(at: operations.now()) else { return }
        if restarting {
            revokeWork()
            playbackEpoch = UUID()
        }
        enqueueCurrent()
        publish()
    }

    /// 采样当前时刻后暂停；重提冻结位置，并撤销仍携带播放意图的旧呈现回调。
    public func pause() async {
        timeline.pause(at: operations.now())
        // 普通 GPU 工作也可能尚未实际呈现；旧 isPlaying 回调不能在暂停后新建活动起点。
        revokeWork()
        playbackEpoch = UUID()
        await scene?.externalVideos?.pause()
        enqueueCurrent()
        publish()
    }

    /// stop 遵守保留位置的暂停语义，不清空图像或重置计数。
    public func stop() async { await pause() }

    /// 暂停并回零，重置跑马灯/占位起点但保留 GIF/WebP 独立进度；无合成或失败时抛对应领域错误。
    public func rewind() async throws {
        try Task.checkCancellation()
        try timeline.rewind(at: operations.now())
        revokeWork()
        scene?.marqueeClock?.reset()
        scene?.placeholderClock?.reset()
        playbackEpoch = UUID()
        await scene?.externalVideos?.pause()
        enqueueCurrent()
        publish()
    }

    /// 接受新微秒位置后同步撤销旧许可，不等待显示完成。
    public func seek(to time: PAGTime) async throws {
        try Task.checkCancellation()
        try timeline.seek(to: time, at: operations.now())
        revokeWork()
        playbackEpoch = UUID()
        enqueueCurrent()
        publish()
    }

    /// 使用统一的整数端点映射定位，进度一落在最后可见微秒。
    public func seek(to progress: PAGProgress) async throws {
        guard let duration = timeline.duration else { throw PAGError.missingComposition }
        try await seek(to: TimeMapping.time(for: progress, duration: duration))
    }

    /// 更新总播放次数，新的收尾意图使旧末帧完成失效。
    public func setRepeatCount(_ count: Int) {
        guard timeline.repeatCount != count else { return }
        timeline.setRepeatCount(count, at: operations.now())
        revokeWork()
        playbackEpoch = UUID()
        enqueueCurrent()
        publish()
    }

    /// 更新最终显示变换并使旧布局代数失效；代数耗尽作为明确主工作失败发布。
    public func setScaleMode(_ mode: PAGScaleMode) {
        guard scaleMode != mode else { return }
        do { revision = try nextRevision() }
        catch { fail(error); return }
        scaleMode = mode
        revokeWork()
        playbackEpoch = UUID()
        presentedTime = nil
        enqueueCurrent()
        publish()
    }

    /// 接受平台的同原点单调微秒；一次 tick 只替换待处理值，不创建额外任务。
    func tick(at now: UInt64) {
        guard timeline.advance(to: now) else { return }
        enqueueCurrent()
        publish()
    }

    /// 暂停并定位后等待有效提交；取消同步结束等待并撤销此请求的提交许可。
    public func render(at time: PAGTime) async throws -> PAGRenderResult {
        try Task.checkCancellation()
        guard scene != nil else { throw PAGError.missingComposition }
        guard timeline.target != .detached else { throw PAGError.missingSurface }
        var accepted = timeline
        let now = operations.now()
        accepted.pause(at: now)
        try accepted.seek(to: time, at: now)
        timeline = accepted
        revokeWork()
        playbackEpoch = UUID()
        publish()
        guard timeline.target == .available else { return .targetUnavailable }
        let waiter = PlaybackRenderWaiter()
        guard let frame = makeFrame(waiter: waiter) else { return .targetUnavailable }
        enqueue(frame)
        let gate = gate
        return try await withTaskCancellationHandler {
            let result = try await waiter.value()
            try Task.checkCancellation()
            return result
        } onCancel: {
            gate.cancel(frame.request.token, waiter: waiter)
            Task { await self.cancelRender(frame.request.token) }
        }
    }

    /// 创建内容或清屏请求；无可用目标、失败或已完成空内容清理时不分配工作。
    private func makeFrame(waiter: PlaybackRenderWaiter? = nil) -> QueuedPlaybackFrame? {
        guard submitter != nil, timeline.target == .available, timeline.failure == nil,
              scene != nil || needsClear else { return nil }
        let token = PlaybackRequestToken(documentID: scene?.composition.storage.identity,
                                         compositionRevision: revision, playbackEpoch: playbackEpoch,
                                         targetEpoch: targetEpoch, requestID: UUID())
        let request = PlaybackFrameRequest(scene: scene, time: timeline.position, scaleMode: scaleMode,
                                           token: token, gate: gate, endsPlayback: timeline.awaitsFinalFrame,
                                           isPlaying: timeline.state == .playing,
                                           auxiliaryTime: PAGTime(microseconds: Int64(min(timeline.activeElapsed,
                                               UInt64(Int64.max)))),
                                           imageAnimationTime: PAGTime(microseconds: Int64(min(timeline.imageElapsed,
                                               UInt64(Int64.max)))), diagnostics: diagnosticSession)
        return QueuedPlaybackFrame(request: request, waiter: waiter)
    }

    /// 普通控制与刷新只保留当前位置；完全相同的有效活动帧可以继续完成。
    func enqueueCurrent() {
        if pending == nil, let frame = active?.frame, gate.permits(frame.request.token),
           frame.request.time == timeline.position, frame.request.endsPlayback == timeline.awaitsFinalFrame,
           frame.request.imageAnimationTime.microseconds == Int64(min(timeline.imageElapsed, UInt64(Int64.max))) {
            return
        }
        if let frame = makeFrame() { enqueue(frame) }
    }

    /// 合并尚未开始的工作；被覆盖的显式等待者立即取消，不等待旧后台任务。
    private func enqueue(_ frame: QueuedPlaybackFrame) {
        if let pending {
            pending.request.diagnostics?.record(.coalesced, token: pending.request.token, time: pending.request.time)
        }
        pending?.waiter?.cancel()
        pending = frame
        startNext()
    }

    /// 至多启动一个拥有句柄的工作；取消中的旧工作未退出前不追加活动任务。
    private func startNext() {
        guard active == nil, let frame = pending, let submitter else { return }
        pending = nil
        guard gate.allow(frame.request.token, unlessCancelled: frame.waiter) else { return }
        let task = Task { [weak self] in
            let result = await PlaybackWork.execute(frame.request, using: submitter)
            await self?.finish(frame, result: result)
        }
        active = ActivePlaybackFrame(frame: frame, task: task)
    }

    /// 完成只写回仍有许可的身份；position 始终由控制命令决定，不被旧 GPU 时刻倒写。
    private func finish(_ frame: QueuedPlaybackFrame, result: Result<PlaybackSubmission, any Error>) {
        guard active?.frame.request.token == frame.request.token else { return }
        active = nil
        let valid = gate.claimCompletion(frame.request.token)
        if valid {
            do {
                switch try result.get() {
                case .submitted(let time):
                    guard let scene = frame.request.scene else { throw PAGError.renderingFailure("unexpectedContentCompletion") }
                    let expected = try SceneTiming.root(at: frame.request.time, in: scene.composition.storage)
                    guard time == expected.representedTime else { throw PAGError.renderingFailure("submittedTime") }
                    presentedTime = time
                    retriesPresentation = false
                    if frame.request.endsPlayback { timeline.didSubmitFinalFrame() }
                    frame.waiter?.resolve(.success(.submitted(time: time, revision: frame.request.token.compositionRevision)))
                case .cleared:
                    guard frame.request.scene == nil else { throw PAGError.renderingFailure("unexpectedClearCompletion") }
                    // 清屏没有PAG时间，不能把透明画面报告成零微秒已经播放。
                    needsClear = false
                    retriesPresentation = false
                    presentedTime = nil
                case .targetUnavailable:
                    // 新挂载的显示树可能尚无drawable；暂停内容也需要一次后续真实刷新恢复首帧。
                    retriesPresentation = true
                    timeline.setTarget(.unavailable, at: operations.now())
                    targetEpoch = UUID()
                    pending?.waiter?.resolve(.success(.targetUnavailable))
                    pending = nil
                    frame.waiter?.resolve(.success(.targetUnavailable))
                }
            } catch is CancellationError {
                frame.waiter?.cancel()
            } catch {
                frame.waiter?.resolve(.failure(error))
                fail(error)
            }
            publish()
        } else {
            frame.request.diagnostics?.record(.discarded, token: frame.request.token, time: frame.request.time)
            frame.waiter?.cancel()
        }
        operations.observe(.workFinished(frame.request.token.requestID, accepted: valid))
        startNext()
    }

    /// 同步撤销 permit 并取消旧工作；保留活动句柄以约束不可取消阶段的并发数量。
    func revokeWork() {
        gate.revoke()
        active?.task.cancel()
        active?.frame.waiter?.cancel()
        pending?.waiter?.cancel()
        pending = nil
    }

    /// 清理显式 render 的取消，只匹配其完整身份，不能取消更新的控制请求。
    private func cancelRender(_ token: PlaybackRequestToken) {
        if active?.frame.request.token == token { active?.task.cancel() }
        if pending?.request.token == token { pending = nil }
    }

    /// 领域失败停止主播放并清理待处理工作；陌生底层错误转换为 Sendable 诊断字符串。
    func fail(_ error: any Error) {
        revokeWork()
        timeline.fail(error as? PAGError ?? .renderingFailure(String(describing: error)))
        publish()
    }

    /// 计算下次公开代数，禁止回绕后把旧提交误认为新状态。
    private func nextRevision() throws -> UInt64 {
        guard revision < .max else { throw PAGError.resourceLimitExceeded("playbackRevision") }
        return revision + 1
    }

    /// 新安装先取消旧准备，并给可重入提交建立独立身份；旧完整场景此时仍可播放。
    private func beginPreparation() -> UUID {
        preparationTask?.cancel()
        preparationTask = nil
        let id = UUID()
        preparationID = id
        return id
    }

    /// 给后台准备建立拥有者句柄，调用者取消也传播给 worker；失败不安装部分场景。
    private func prepare(_ composition: PAGComposition, reusing previous: PreparedScene?) async throws -> PreparedScene {
        let operation = operations.prepare
        let task = Task { try await operation(composition, previous) }
        preparationTask = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 只回收当前事务的身份与句柄，迟到旧事务不能清掉更新的准备任务。
    private func finishPreparation(_ id: UUID) {
        guard preparationID == id else { return }
        preparationID = nil
        preparationTask = nil
    }

    /// 给每位消费者发布同一不可变快照；bufferingNewest 自动丢弃尚未消费的旧值。
    func publish() {
        let value = snapshot
        displayBinding?.requestTicks(requiresDisplayRefresh)
        for observer in observers.values { observer.yield(value) }
    }

    /// 消费结束后移除 continuation；多个终止通知不会重复减少计数。
    private func removeObserver(_ id: UUID) {
        guard observers.removeValue(forKey: id) != nil else { return }
        operations.observe(.subscriptionCount(observers.count))
    }
}
