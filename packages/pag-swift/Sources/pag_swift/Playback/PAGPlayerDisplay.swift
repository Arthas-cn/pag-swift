import Foundation

/// 播放器的表面预约与平台生命周期；与内容和时间调度共享同一 actor。
extension PAGPlayer {
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

}
