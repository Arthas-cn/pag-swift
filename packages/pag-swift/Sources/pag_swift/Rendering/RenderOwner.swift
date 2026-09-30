import Dispatch
import Foundation
import Metal

/// 专用串行执行器上的GPU所有者；输入准备、drawable编码与提交均不进入主线程。
actor RenderOwner: PlaybackSubmitting {
    /// actor 工作使用独立 Dispatch 串行队列，可阻塞的 drawable 获取不占协作执行器或主线程。
    nonisolated private let executor = DispatchSerialQueue(label: "pag.render", qos: .userInitiated)
    /// Swift actor 的真实执行器，所有隔离方法和 GPU 对象访问均落在这条队列。
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    /// 同步设备检查后通过 sending 一次性转交的设备，不向 UI 返回裸值。
    private let device: any MTLDevice
    /// 在本 owner 内创建并持有的命令队列，nil 表示尚未完成首次目标配置。
    private var commandQueue: (any MTLCommandQueue)?
    /// 首次成功配置后绑定的唯一显示桥；每个surface独占一个owner，不能跨表面复用裸GPU状态。
    private var target: DisplayTargetBox?
    /// 首次实际帧准备时创建的有界输入缓存和管线，裸资源只属于本actor。
    private var resources: MetalResources?
    /// 等待后台求值或GPU完成时仍保持占用，防止actor可重入导致第二份帧绕过单活动工作上限。
    private var isSubmitting = false
    /// 绑定交接等待活动提交真正退出的屏障；显示租约归还不等于actor恢复已结束。
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// 可选内部编码诊断，调用时不持有播放或mailbox锁，不暴露任何Metal对象。
    private let observe: (@Sendable (RenderEvent) -> Void)?

    /// 接收断开创建域别名的设备；这里只接收所有权，重配置在后台隔离方法进行。
    init(device: sending any MTLDevice, observe: (@Sendable (RenderEvent) -> Void)? = nil) {
        self.device = device
        self.observe = observe
    }

    /// 独占配置目标的 Metal 属性和命令队列；过期事务抛取消，设备无法建队列抛 graphicsUnavailable。
    func prepareTarget(_ target: DisplayTargetBox, mutation: UUID) throws -> RenderDeviceInfo {
        dispatchPrecondition(condition: .onQueue(executor))
        try Task.checkCancellation()
        guard self.target == nil || self.target === target else { throw PAGError.renderingFailure("renderOwnerTarget") }
        guard let lease = target.mailbox.acquireConfiguration(for: mutation) else { throw CancellationError() }
        defer { target.mailbox.release(lease) }
        if commandQueue == nil {
            guard let queue = device.makeCommandQueue() else { throw PAGError.graphicsUnavailable }
            commandQueue = queue
        }
        try target.configure(device: device, lease: lease, on: self)
        // 配置系统调用也可能与控制撤销竞争，不能把迟到配置的成功发布给新宿主事务。
        try Task.checkCancellation()
        guard target.mailbox.isCurrent(lease) else { throw CancellationError() }
        self.target = target
        return RenderDeviceInfo(name: device.name, maximumBufferLength: device.maxBufferLength,
                                isMainThread: Thread.isMainThread)
    }

    /// 完整准备后直接编码drawable，并等待真实GPU完成；取消不提前释放仍被GPU使用的显示租约。
    func submit(_ request: PlaybackFrameRequest) async throws -> PlaybackSubmission {
        dispatchPrecondition(condition: .onQueue(executor))
        try Task.checkCancellation()
        guard let target, let commandQueue else { return .targetUnavailable }
        let state = target.mailbox.snapshot
        try validate(request, target: target)
        guard !state.isBlocked, state.configuration.isMounted, state.configuration.isActive,
              let geometry = state.configuration.geometry else { return .targetUnavailable }
        guard !isSubmitting else { throw PAGError.renderingFailure("concurrentMetalSubmission") }
        isSubmitting = true
        defer {
            isSubmitting = false
            let waiters = idleWaiters
            idleWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let batch: MetalFrameBatch?
        let representedTime: PAGTime?
        if let scene = request.scene {
            guard request.token.documentID == scene.composition.storage.identity else {
                throw PAGError.renderingFailure("metalRequestDocument")
            }
            // 求值尚未持有显示租约，resize/detach可以立即撤销，返回后再复核两种代数。
            let frame = try await FramePlanner.prepare(scene, at: request.time, targetSize: geometry.size,
                                                       scale: geometry.scale, mode: request.scaleMode)
            try validate(request, target: target)
            let resources: MetalResources
            if let existing = self.resources { resources = existing }
            else {
                resources = try MetalResources(device: device)
                self.resources = resources
            }
            batch = try MetalFramePreparation.prepare(frame, width: geometry.pixelWidth, height: geometry.pixelHeight,
                                                       resources: resources)
            representedTime = frame.plan.time.representedTime
        } else {
            // 清屏不借用假场景，也不为零绘制编译管线或分配输入buffer。
            guard request.token.documentID == nil, request.time == .zero, !request.endsPlayback else {
                throw PAGError.renderingFailure("metalClearRequest")
            }
            batch = nil
            representedTime = nil
        }
        // await只在真正GPU完成后返回；取消不能提前把仍使用中的组纹理放回池。
        defer {
            // MTLTexture引用不替代CVMetalTexture的生命周期；显式保活整批输入直到真正GPU完成。
            withExtendedLifetime(batch) { batch?.releaseTransients() }
        }
        try validate(request, target: target)
        guard let lease = target.mailbox.acquireDrawing(for: request.token.targetEpoch) else {
            try validate(request, target: target)
            return .targetUnavailable
        }
        let result: Result<Bool, any Error> = await withCheckedContinuation { continuation in
            let completion = MetalSubmissionCompletion(continuation: continuation, mailbox: target.mailbox, lease: lease)
            do {
                let obtained = try target.withDrawable(lease: lease, on: self) { drawable in
                    guard let buffer = commandQueue.makeCommandBuffer() else {
                        throw PAGError.renderingFailure("metalCommandBufferAllocation")
                    }
                    buffer.label = "pag.frame"
                    if let batch { try batch.encode(to: drawable, commandBuffer: buffer, geometry: geometry) }
                    else { try MetalFrameBatch.clear(to: drawable, commandBuffer: buffer, geometry: geometry) }
                    observe?(.encoded(request.token.requestID, drawCount: batch?.drawCount ?? 0))
                    let mailbox = target.mailbox
                    let observe = self.observe
                    buffer.addCompletedHandler { completed in
                        // 系统回调只转换状态并归还值租约，不读取actor字段或跨域传回裸buffer。
                        let outcome: Result<Bool, any Error>
                        if completed.status == .completed {
                            outcome = .success(true)
                            // 时间戳只在真实完成回调内读取；诊断不影响提交成功或迟到丢弃的规则。
                            if let observe {
                                observe(.gpuCompleted(request.token.requestID,
                                                      seconds: completed.gpuEndTime - completed.gpuStartTime))
                            }
                        }
                        else {
                            let error = completed.error as NSError?
                            outcome = .failure(PAGError.renderingFailure("metalCommandBuffer: \(error?.domain ?? "unknown")/\(error?.code ?? -1)"))
                        }
                        completion.gpuFinished(outcome)
                    }
                    try Task.checkCancellation()
                    // 固定锁序：播放gate → mailbox。撤销和显示变更都能阻止尚未入队的旧帧。
                    let committed = request.gate.withPermission(for: request.token) {
                        mailbox.withDrawingPermission(for: lease) {
                            buffer.present(drawable)
                            buffer.commit()
                            return true
                        } == true
                    } == true
                    guard committed else { throw CancellationError() }
                }
                if obtained { completion.didCommit() }
                else { completion.abandon(.success(false)) }
            } catch {
                // 尚未commit即可放弃租约；丢弃buffer也可能带来系统回调，两条路径必须竞争同一出口。
                completion.abandon(.failure(error))
            }
        }
        try validate(request, target: target)
        guard try result.get() else { return .targetUnavailable }
        return representedTime.map(PlaybackSubmission.submitted) ?? .cleared
    }

    /// 异步等当前提交退出；清理不因调用方取消而提前把仍占用的owner交给下一绑定。
    func waitUntilIdle() async {
        guard isSubmitting else { return }
        await withCheckedContinuation {
            idleWaiters.append($0)
            observe?(.waitingForIdle)
        }
    }

    /// 每个暂停点或长系统调用后校验取消、播放许可和实际显示代数；过期成功不得传播给控制器。
    private func validate(_ request: PlaybackFrameRequest, target: DisplayTargetBox) throws {
        try Task.checkCancellation()
        let state = target.mailbox.snapshot
        guard !state.isClosed, state.epoch == request.token.targetEpoch, request.gate.permits(request.token) else {
            throw CancellationError()
        }
    }
}

/// 渲染owner内部小值诊断；编码完成不代表GPU已经执行或显示。
enum RenderEvent: Sendable {
    /// 已注册活动提交退出屏障；用于确定性验证两个绑定交接，不暴露continuation。
    case waitingForIdle
    /// 最后许可检查前已经编码的请求身份和图元数，用于确定性验证撤销窗口。
    case encoded(UUID, drawCount: Int)
    /// 系统报告已完成的GPU区间秒数；不含CPU准备/显示等待，也不代表该请求仍是当前代数。
    case gpuCompleted(UUID, seconds: Double)
}

/// GPU 配置完成后的内部纯值诊断，不暴露任何 Metal 对象。
struct RenderDeviceInfo: Sendable {
    /// 系统报告的设备名称，只用于诊断。
    let name: String
    /// 单个 buffer 的实际设备字节上限，后续资源分配仍检查创建结果。
    let maximumBufferLength: Int
    /// 配置调用实际是否位于主线程，测试用来验证专用执行域。
    let isMainThread: Bool
}
