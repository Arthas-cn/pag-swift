import Foundation

/// 统一播放控制actor，串行接受控制并发布快照；求值和GPU工作留在后台所有者。
public actor PAGPlayer {
    /// 完整场景资源；nil 表示没有可求值的合成。
    private var scene: PreparedScene?
    /// 纯值时间状态机，不在其中启动任务。
    private var timeline = PlaybackTimeline()
    /// 最后有效提交的量化时间；换合成代数后重新等待首帧。
    private var presentedTime: PAGTime?
    /// 空内容尚需清理当前目标；成功清屏后归零，换显示代数或再次nil安装时重新置位。
    private var needsClear = true
    /// 最近提交暂时拿不到drawable；即使ready/paused也需真实刷新恢复，成功呈现后停止重试。
    private var retriesPresentation = false
    /// 对外可观察的合成提交代数，不回绕。
    private var revision: UInt64 = 0
    /// 显示缩放设置，换文档时保留。
    private var scaleMode: PAGScaleMode = .aspectFit
    /// 时间控制撤销的当前身份。
    private var playbackEpoch = UUID()
    /// 显示生命周期撤销的当前身份。
    private var targetEpoch = UUID()
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
    private var submitter: (any PlaybackSubmitting)?
    /// 播放器生命周期内固定的绑定拥有者身份。
    private let playerID = UUID()
    /// 最近一次绑定控制请求，迟到预约不能覆盖新指令。
    private var bindingTransaction = UUID()
    /// 最新接受的原生宿主意图；nil表示最近绑定由独立公开API管理。
    private var hostRequest: DisplayHostToken?
    /// 实际已绑定表面的宿主身份，与尚在准备的新请求分开，便于只清理旧目标。
    private var boundHost: DisplayHostToken?
    /// 当前强持有的独立显示表面；nil表示未绑定。
    private var surface: PAGSurface?
    /// 已安装的独占预约，小值通道不反向保活播放器。
    private var displayBinding: DisplayBinding?
    /// 唯一显示消息消费任务，display tick不逐次创建Task。
    private var displayTask: Task<Void, Never>?
    /// 尚未完成的表面预约；新attach/detach同步取消旧worker。
    private var surfacePreparation: (surface: PAGSurface, task: Task<DisplayBinding, any Error>)?
    /// 单调时钟、场景准备和内部诊断注入。
    private let operations: PlaybackOperations
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
        try Task.checkCancellation()
        let id = beginPreparation()
        defer { finishPreparation(id) }
        let prepared: PreparedScene?
        if let composition { prepared = try await prepare(composition, reusing: scene) }
        else { prepared = nil }
        try Task.checkCancellation()
        guard preparationID == id else { throw CancellationError() }
        let next = try nextRevision()
        try timeline.install(duration: composition?.duration)
        revokeWork()
        playbackEpoch = UUID()
        scene = prepared
        needsClear = prepared == nil
        revision = next
        presentedTime = nil
        enqueueCurrent()
        publish()
    }

    /// 完整准备同文档编辑后保留当前时间与意图；跨文档或准备失败不修改原状态。
    public func replaceComposition(_ composition: PAGComposition) async throws {
        try Task.checkCancellation()
        guard let previous = scene else { throw PAGError.missingComposition }
        guard composition.storage.identity == previous.composition.storage.identity else {
            throw PAGError.invalidArgument("compositionDocument")
        }
        let id = beginPreparation()
        defer { finishPreparation(id) }
        let prepared = try await prepare(composition, reusing: previous)
        try Task.checkCancellation()
        guard preparationID == id else { throw CancellationError() }
        let next = try nextRevision()
        let now = operations.now()
        timeline.advance(to: now)
        try timeline.replace(duration: composition.duration, at: now)
        revokeWork()
        playbackEpoch = UUID()
        scene = prepared
        needsClear = false
        revision = next
        presentedTime = nil
        enqueueCurrent()
        publish()
    }

    /// 绑定独立表面；其他播放器占用时抛surfaceInUse，失败或取消保留原有效绑定。
    public func attach(to surface: PAGSurface) async throws {
        try Task.checkCancellation()
        hostRequest = nil
        try await attach(to: surface, host: nil)
    }

    /// 宿主开始准备显示目标；身份无效时不夺取新宿主的失败报告权限。
    func beginHostRequest(_ token: DisplayHostToken) throws {
        try Task.checkCancellation()
        guard token.isValid else { throw CancellationError() }
        hostRequest = token
    }

    /// 只有最新有效宿主能报告创建或挂载失败，旧异步错误不能覆盖新目标状态。
    func reportHostFailure(_ error: PAGError, token: DisplayHostToken) {
        guard hostRequest === token, token.isValid else { return }
        fail(error)
    }

    /// 原生宿主沿同一绑定实现接入；nil仅用于公开独立surface调用。
    func attach(to surface: PAGSurface, host token: DisplayHostToken?) async throws {
        try Task.checkCancellation()
        if let token, hostRequest !== token || !token.isValid { throw CancellationError() }
        let transaction = UUID()
        bindingTransaction = transaction
        surfacePreparation?.task.cancel()
        surfacePreparation = nil
        if self.surface === surface, displayBinding?.isValid == true { boundHost = token; return }
        let playerID = playerID, now = operations.now
        let task = Task { [weak self] in
            try await surface.claim(playerID: playerID, now: now) { [weak self] id, event in
                await self?.receiveDisplay(event, from: id)
            }
        }
        surfacePreparation = (surface, task)
        defer { if bindingTransaction == transaction { surfacePreparation = nil } }
        let candidate = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard bindingTransaction == transaction, !Task.isCancelled, candidate.isValid,
              token == nil || (hostRequest === token && token?.isValid == true) else {
            await surface.release(candidate)
            throw CancellationError()
        }
        let previousSurface = self.surface, previous = displayBinding
        // 新预约已经完整就绪，才同步撤销旧控制许可；后续清理只持有旧身份。
        revokeWork()
        displayTask?.cancel()
        previous?.cancel()
        self.surface = surface
        boundHost = token
        displayBinding = candidate
        submitter = candidate.owner
        receiveDisplay(DisplayBindingEvent(target: candidate.mailbox.snapshot, time: nil, failure: nil), from: candidate.id)
        let events = candidate.events
        displayTask = Task { [weak self] in
            for await event in events { await self?.receiveDisplay(event, from: candidate.id) }
        }
        if let previousSurface, let previous { await previousSurface.release(previous) }
    }

    /// 撤销绑定及尚未完成的预约，等旧owner退出；保留合成、位置和播放意图。
    public func detachSurface() async {
        hostRequest = nil
        bindingTransaction = UUID()
        let preparation = surfacePreparation
        surfacePreparation = nil
        preparation?.task.cancel()
        let previousSurface = surface, previous = displayBinding
        revokeWork()
        displayTask?.cancel()
        displayTask = nil
        previous?.cancel()
        displayBinding = nil
        surface = nil
        boundHost = nil
        submitter = nil
        updateTarget(.detached)
        if let previousSurface, let previous { await previousSurface.release(previous) }
        // 已经返回的预约也可能还没装入本actor；必须排空它，避免detach后留下幽灵占用。
        if let preparation, let candidate = try? await preparation.task.value { await preparation.surface.release(candidate) }
    }

    /// 旧宿主清理只解除自身仍占有的目标；已经切到另一宿主或独立surface时直接忽略。
    func detach(from surface: PAGSurface, host token: DisplayHostToken) async {
        let preparation = surfacePreparation?.surface === surface ? surfacePreparation : nil
        if preparation != nil {
            bindingTransaction = UUID()
            surfacePreparation = nil
            preparation?.task.cancel()
        }
        if self.surface === surface, boundHost === token {
            let previous = displayBinding
            revokeWork()
            displayTask?.cancel()
            displayTask = nil
            previous?.cancel()
            displayBinding = nil
            self.surface = nil
            boundHost = nil
            submitter = nil
            updateTarget(.detached)
            if hostRequest === token { hostRequest = nil }
            if let previous { await surface.release(previous) }
        }
        // 新宿主可能已经在另一个surface预约；只排空旧宿主自己的准备，不能取消新事务。
        if let preparation, let candidate = try? await preparation.task.value { await surface.release(candidate) }
    }

    /// 只接收当前预约与显示代数，消息合并不丢最终配置；明确宿主调用也通过此入口确认。
    private func receiveDisplay(_ event: DisplayBindingEvent, from identity: UUID) {
        guard let displayBinding, displayBinding.id == identity, displayBinding.isValid else { return }
        let actual = displayBinding.mailbox.snapshot
        guard actual.epoch == event.target.epoch else { return }
        if let failure = event.failure { fail(failure); return }
        let configuration = actual.configuration
        let available = displayBinding.isRefreshAvailable && !actual.isBlocked && !actual.isClosed && configuration.isMounted
            && configuration.isActive && configuration.geometry != nil
        updateTarget(available ? .available : .unavailable, epoch: actual.epoch)
        if available, let time = event.time { tick(at: time) }
    }

    /// 宿主发送目标状态与mailbox实际代数；nil仅供无平台目标的调度测试自动生成身份。
    func updateTarget(_ target: PlaybackTargetState, geometryChanged: Bool = false, epoch: UUID? = nil) {
        guard target != timeline.target || geometryChanged || (epoch != nil && epoch != targetEpoch) else { return }
        if scene == nil { needsClear = true }
        timeline.setTarget(target, at: operations.now())
        targetEpoch = epoch ?? UUID()
        revokeWork()
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

    /// 采样当前时刻后暂停；已接受位置仍可提交，但显式 render 被新控制取代。
    public func pause() async {
        timeline.pause(at: operations.now())
        if active?.frame.waiter != nil || pending?.waiter != nil {
            revokeWork()
            playbackEpoch = UUID()
        }
        enqueueCurrent()
        publish()
    }

    /// stop 遵守保留位置的暂停语义，不清空图像或重置计数。
    public func stop() async { await pause() }

    /// 暂停并回零，撤销所有旧时间工作；无合成或失败时抛对应领域错误。
    public func rewind() async throws {
        try Task.checkCancellation()
        try timeline.rewind()
        revokeWork()
        playbackEpoch = UUID()
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
                                           token: token, gate: gate, endsPlayback: timeline.awaitsFinalFrame)
        return QueuedPlaybackFrame(request: request, waiter: waiter)
    }

    /// 普通控制与刷新只保留当前位置；完全相同的有效活动帧可以继续完成。
    private func enqueueCurrent() {
        if pending == nil, let frame = active?.frame, gate.permits(frame.request.token),
           frame.request.time == timeline.position, frame.request.endsPlayback == timeline.awaitsFinalFrame {
            return
        }
        if let frame = makeFrame() { enqueue(frame) }
    }

    /// 合并尚未开始的工作；被覆盖的显式等待者立即取消，不等待旧后台任务。
    private func enqueue(_ frame: QueuedPlaybackFrame) {
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
            frame.waiter?.cancel()
        }
        operations.observe(.workFinished(frame.request.token.requestID, accepted: valid))
        startNext()
    }

    /// 同步撤销 permit 并取消旧工作；保留活动句柄以约束不可取消阶段的并发数量。
    private func revokeWork() {
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
    private func fail(_ error: any Error) {
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
    private func publish() {
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
