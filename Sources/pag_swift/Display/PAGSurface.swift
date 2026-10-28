import Metal
import QuartzCore

/// 独立的Metal显示目标；拥有库创建的显示层，可挂到普通CALayer，不提供离屏出图。
@MainActor public final class PAGSurface {
    /// 唯一经过租约审计的裸层桥，不向调用方暴露Metal层别名。
    private let target: DisplayTargetBox
    /// 此表面唯一的后台GPU所有者。
    private let owner: RenderOwner
    /// 最近请求的完整宿主配置，更新事务失败时恢复上一份。
    private var configuration = DisplayTargetConfiguration()
    /// 最近请求的父层；nil表示显式卸载。
    private var parent: CALayer?
    /// 已经实际安装的父层，用于避免普通resize反复重新挂载。
    private weak var installedParent: CALayer?
    /// 是否已经由后台owner完成设备与管线目标配置。
    private var isConfigured = false
    /// 当前独占预约；取消后的旧身份不能解除新预约。
    private var binding: DisplayBinding?
    /// 当前预约的播放意图消费任务，不强持有表面。
    private var tickTask: Task<Void, Never>?
    /// 当前主actor平台刷新适配，只在需要播放且目标可用时运行。
    private var driver: DisplayRefreshDriver?
    /// 宿主或测试可提供刷新工厂；nil使用独立surface的平台默认实现。
    private let refreshFactory: (@MainActor (@escaping @MainActor () -> Void) -> DisplayRefreshDriver)?

    /// 创建透明目标；没有Metal设备时抛graphicsUnavailable，重资源配置留到后台。
    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw PAGError.graphicsUnavailable }
        owner = RenderOwner(device: device)
        target = DisplayTargetBox()
        refreshFactory = nil
    }

    /// 内部生命周期测试注入同一显示桥和后台owner；不改变公开设备创建与所有权合同。
    init(target: DisplayTargetBox, owner: RenderOwner,
         refreshFactory: (@MainActor (Any, Selector) -> CADisplayLink?)? = nil) {
        self.target = target
        self.owner = owner
        if let refreshFactory {
            self.refreshFactory = { refresh in DisplayRefreshDriver(factory: refreshFactory, refresh: refresh) }
        } else { self.refreshFactory = nil }
    }

    /// 原生宿主注入实际View刷新源；提前建立被动观察，最初隐藏的祖先恢复也能通知布局。
    init(refreshFactory: @escaping @MainActor (@escaping @MainActor () -> Void) -> DisplayRefreshDriver) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw PAGError.graphicsUnavailable }
        owner = RenderOwner(device: device)
        target = DisplayTargetBox()
        self.refreshFactory = refreshFactory
        driver = refreshFactory { [weak self] in self?.binding?.publish(tick: true) }
    }

    /// 同步宿主事件先关闭提交段，再让异步配置排空GPU；不在这里修改裸Metal层。
    func suspendForHostUpdate() {
        _ = target.mailbox.beginMutation()
        driver?.setActive(false)
        binding?.publish()
    }

    /// 原生宿主一次应用完整目标状态；零布局保留最后合法geometry且不允许呈现。
    func applyHostConfiguration(parent: CALayer?, geometry: DisplayGeometry?, isActive: Bool) async throws {
        let next = DisplayTargetConfiguration(geometry: geometry ?? configuration.geometry, isMounted: parent != nil,
                                              isActive: isActive && parent != nil && geometry != nil)
        try await apply(parent: parent, configuration: next)
    }

    /// 关闭新访问后异步排空再拆层，不在主线程等待GPU，也不让link反向保活表面。
    isolated deinit {
        binding?.cancel()
        tickTask?.cancel()
        driver?.invalidate()
        target.mailbox.close()
        let target = target
        Task { @MainActor in await target.shutdown() }
    }

    /// 挂到调用方普通父层；等待旧访问退出，被更新事务取代或调用者取消时抛CancellationError。
    public func attach(to parentLayer: CALayer) async throws {
        var next = configuration
        next.isMounted = true
        try await apply(parent: parentLayer, configuration: next)
    }

    /// 更新正逻辑尺寸和有限正像素倍率；非法参数或像素超限失败，不改变原布局。
    public func resize(to size: PAGSize, scale: Double) async throws {
        var next = configuration
        next.geometry = try DisplayGeometry(size: size, scale: scale)
        try await apply(parent: parent, configuration: next)
    }

    /// 声明宿主是否允许呈现，默认false；隐藏时冻结播放，仍保留最近合法布局。
    public func setPresentationActive(_ isActive: Bool) async {
        guard configuration.isActive != isActive else {
            // 独立宿主可在屏幕恢复后再次声明active，以重试曾经无法建立的系统link。
            updateDriver()
            await binding?.synchronize()
            return
        }
        var next = configuration
        next.isActive = isActive
        do { try await apply(parent: parent, configuration: next, checksCancellation: false) }
        // 非抛出宿主调用只忽略被更新事务取代；外层取消不能中断已开始的隐藏清理。
        catch is CancellationError { }
        catch { await binding?.synchronize(failure: error as? PAGError ?? .renderingFailure(String(describing: error))) }
    }

    /// 撤销显示并等旧访问退出后拆层；保留布局和播放器绑定，重新挂载后仍需显式激活。
    public func detach() async {
        var next = configuration
        next.isMounted = false
        next.isActive = false
        do { try await apply(parent: nil, configuration: next, checksCancellation: false) }
        // 更新宿主事务已接管时不再拆它的层；旧清理不触碰新代数。
        catch is CancellationError { }
        catch { await binding?.synchronize(failure: error as? PAGError ?? .renderingFailure(String(describing: error))) }
    }

    /// 预约独占owner，失败保留其他有效拥有者；新预约须排空旧工作后才能交给播放器。
    func claim(playerID: UUID, now: @escaping @Sendable () -> UInt64,
               notify: @escaping @Sendable (UUID, DisplayBindingEvent) async -> Void) async throws -> DisplayBinding {
        try Task.checkCancellation()
        if let binding, binding.isValid, binding.playerID != playerID { throw PAGError.surfaceInUse }
        binding?.cancel()
        tickTask?.cancel()
        let candidate = DisplayBinding(playerID: playerID, owner: owner, mailbox: target.mailbox, now: now, notify: notify)
        binding = candidate
        do {
            try await apply(parent: parent, configuration: configuration)
            try Task.checkCancellation()
            guard binding === candidate, candidate.isValid else { throw CancellationError() }
            let requests = candidate.tickRequests
            tickTask = Task { [weak self] in
                for await _ in requests { self?.updateDriver(for: candidate.id) }
            }
            candidate.publish()
            return candidate
        } catch {
            candidate.cancel()
            if binding === candidate { binding = nil; updateDriver() }
            throw error
        }
    }

    /// 只解除匹配预约；调用方已同步撤销播放gate，排空完成前不复用owner活动槽。
    func release(_ candidate: DisplayBinding) async {
        candidate.cancel()
        guard binding === candidate else { return }
        binding = nil
        tickTask?.cancel()
        tickTask = nil
        updateDriver()
        await owner.waitUntilIdle()
    }

    /// 一次完整主actor配置事务；取消/失败且身份仍有效时恢复已发布配置，不留下blocked目标。
    private func apply(parent nextParent: CALayer?, configuration next: DisplayTargetConfiguration,
                       checksCancellation: Bool = true) async throws {
        if checksCancellation { try Task.checkCancellation() }
        let previousParent = installedParent
        let published = target.mailbox.snapshot.configuration
        guard let mutation = target.mailbox.beginMutation() else { throw CancellationError() }
        parent = nextParent
        configuration = next
        binding?.publish()
        updateDriver()
        do {
            await owner.waitUntilIdle()
            guard await target.mailbox.waitUntilIdle(for: mutation) else { throw CancellationError() }
            if checksCancellation { try Task.checkCancellation() }
            if !isConfigured, next.isMounted {
                // 非抛出清理调用不受外层任务取消影响；预约/挂载的取消仍显式传给配置worker。
                let setup = Task { try await owner.prepareTarget(target, mutation: mutation) }
                if checksCancellation {
                    _ = try await withTaskCancellationHandler { try await setup.value } onCancel: { setup.cancel() }
                } else { _ = try await setup.value }
                isConfigured = true
            }
            if checksCancellation { try Task.checkCancellation() }
            guard target.mailbox.snapshot.epoch == mutation else { throw CancellationError() }
            if let nextParent {
                if installedParent !== nextParent {
                    guard target.mount(to: nextParent, mutation: mutation) else { throw CancellationError() }
                }
            } else if !target.unmount(mutation: mutation) { throw CancellationError() }
            if let geometry = next.geometry, !target.resize(to: geometry, mutation: mutation) { throw CancellationError() }
            guard target.mailbox.finishMutation(mutation, configuration: next) else { throw CancellationError() }
            installedParent = nextParent
        } catch {
            // 更新事务已经接管时只能退出；否则回滚本次尚未安装的请求并开放原有效目标。
            if target.mailbox.finishMutation(mutation, configuration: published) {
                parent = previousParent
                configuration = published
                binding?.publish()
                updateDriver()
                await binding?.synchronize()
            }
            throw error
        }
        binding?.publish()
        updateDriver()
        await binding?.synchronize()
    }

    /// 只为当前预约更新link；迟到的旧消费任务不操作新的刷新源。
    private func updateDriver(for identity: UUID? = nil) {
        if let identity, binding?.id != identity { return }
        let snapshot = target.mailbox.snapshot
        let active = binding?.wantsTicks == true && !snapshot.isBlocked && !snapshot.isClosed
            && snapshot.configuration.isMounted && snapshot.configuration.isActive && snapshot.configuration.geometry != nil
        if active, driver == nil || driver?.isAvailable == false {
            driver?.invalidate()
            let refresh: @MainActor () -> Void = { [weak self] in self?.binding?.publish(tick: true) }
            driver = refreshFactory?(refresh) ?? DisplayRefreshDriver(refresh: refresh)
            binding?.setRefreshAvailable(driver?.isAvailable == true)
        }
        driver?.setActive(active)
    }
}
