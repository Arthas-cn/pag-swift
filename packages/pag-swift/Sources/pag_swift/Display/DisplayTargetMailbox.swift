import Foundation
import Synchronization

/// 主 actor 与专用 render owner 的值信箱；锁内不访问层、不取 drawable、不等 GPU。
final class DisplayTargetMailbox: Sendable {
    /// 配置、事务和唯一访问租约的短锁状态。
    private let storage = Mutex<DisplayMailboxStorage>(DisplayMailboxStorage())
    /// 可选的内部等待诊断，默认不安装；回调永远在值锁外执行。
    private let observe: (@Sendable (DisplayTargetEvent) -> Void)?

    /// 创建没有平台资源的信箱，测试可观察确定性的等待注册点。
    init(observe: (@Sendable (DisplayTargetEvent) -> Void)? = nil) {
        self.observe = observe
    }

    /// 读取一致的小值快照，不能由此取得裸平台对象。
    var snapshot: DisplayTargetSnapshot {
        storage.withLock { state in
            DisplayTargetSnapshot(epoch: state.epoch, configuration: state.configuration,
                                  isBlocked: state.isBlocked, isClosed: state.isClosed,
                                  hasLease: state.lease != nil, waitingCount: state.waiters.count + state.closeWaiters.count)
        }
    }

    /// 更换代数并停止新绘制；旧等待者立即返回 false，旧租约须自行退出后归还。
    func beginMutation() -> UUID? {
        let result = storage.withLock { state -> (UUID?, [CheckedContinuation<Bool, Never>]) in
            guard !state.isClosed else { return (nil, []) }
            state.epoch = UUID()
            state.isBlocked = true
            let old = Array(state.waiters.values)
            state.waiters.removeAll()
            return (state.epoch, old)
        }
        for waiter in result.1 { waiter.resume(returning: false) }
        return result.0
    }

    /// 异步等旧租约退出；false 表示已被更新事务或关闭取代，不能继续修改 UI 层。
    func waitUntilIdle(for mutation: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            let immediate = storage.withLock { state -> Bool? in
                guard state.epoch == mutation, state.isBlocked, !state.isClosed else { return false }
                guard state.lease != nil else { return true }
                state.waiters[UUID()] = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
            else { observe?(.waitingForMutation(mutation)) }
        }
    }

    /// 原子发布已完成的宿主配置；当前还有访问租约或事务过期时拒绝提交。
    @discardableResult func finishMutation(_ mutation: UUID, configuration: DisplayTargetConfiguration) -> Bool {
        storage.withLock { state in
            guard state.epoch == mutation, state.isBlocked, !state.isClosed, state.lease == nil else { return false }
            state.configuration = configuration
            state.isBlocked = false
            return true
        }
    }

    /// 后台设备/渲染属性配置的独占租约；主 actor 必须等待它归还再操作层关系。
    func acquireConfiguration(for mutation: UUID) -> DisplayTargetLease? {
        acquireMutation(mutation, kind: .configuration)
    }

    /// 主 actor 层树/几何修改的独占租约；配置 owner 也不能与这段操作重叠。
    func acquireMainMutation(for mutation: UUID) -> DisplayTargetLease? {
        acquireMutation(mutation, kind: .mainMutation)
    }

    /// 为已知显示代数申请唯一绘制租约；隐藏、未布局、未挂载或事务期间均返回 nil。
    func acquireDrawing(for epoch: UUID) -> DisplayTargetLease? {
        storage.withLock { state in
            guard state.epoch == epoch, !state.isBlocked, !state.isClosed, state.lease == nil,
                  state.configuration.isMounted, state.configuration.isActive,
                  let geometry = state.configuration.geometry else { return nil }
            let lease = DisplayTargetLease(id: UUID(), epoch: epoch, kind: .drawing(geometry))
            state.lease = lease
            return lease
        }
    }

    /// 复核系统调用返回后的租约；代数变化或关闭后旧租约只能释放资源，不能继续提交。
    func isCurrent(_ lease: DisplayTargetLease) -> Bool {
        storage.withLock { state in
            state.lease == lease && state.epoch == lease.epoch && !state.isClosed
        }
    }

    /// 最后提交与显示事务互斥；body仅允许已编码command buffer的present/commit，不得取drawable、等待或反向取播放gate。
    func withDrawingPermission<Result>(for lease: DisplayTargetLease, _ body: () throws -> Result) rethrows -> Result? {
        try storage.withLock { state in
            guard state.lease == lease, state.epoch == lease.epoch, !state.isBlocked, !state.isClosed,
                  case .drawing = lease.kind else { return nil }
            return try body()
        }
    }

    /// 精确归还自身租约，重复/外来释放无效；所有 continuation 都在锁外恢复。
    @discardableResult func release(_ lease: DisplayTargetLease) -> Bool {
        let result = storage.withLock { state -> (Bool, [CheckedContinuation<Bool, Never>], [CheckedContinuation<Void, Never>]) in
            guard state.lease == lease else { return (false, [], []) }
            state.lease = nil
            let waiters = Array(state.waiters.values)
            let closing = state.closeWaiters
            state.waiters.removeAll()
            state.closeWaiters.removeAll()
            return (true, waiters, closing)
        }
        for waiter in result.1 { waiter.resume(returning: true) }
        for waiter in result.2 { waiter.resume() }
        return result.0
    }

    /// 不可逆关闭并撤销当前代数；不是假装取消已经开始的 GPU 工作。
    func close() {
        let waiters = storage.withLock { state -> [CheckedContinuation<Bool, Never>] in
            guard !state.isClosed else { return [] }
            state.isClosed = true
            state.isBlocked = true
            state.epoch = UUID()
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: false) }
    }

    /// 关闭后的最后清理屏障；即使调用任务取消，也必须等平台访问退出才允许卸载层。
    func waitUntilReleased() async {
        await withCheckedContinuation { continuation in
            let immediate = storage.withLock { state in
                precondition(state.isClosed, "关闭清理前必须先撤销所有新访问")
                guard state.lease != nil else { return true }
                state.closeWaiters.append(continuation)
                return false
            }
            if immediate { continuation.resume() }
            else { observe?(.waitingForClose) }
        }
    }

    /// 两种事务访问共用互斥门，调用者只能在自己的隔离域使用对应租约。
    private func acquireMutation(_ mutation: UUID, kind: DisplayAccessKind) -> DisplayTargetLease? {
        storage.withLock { state in
            guard state.epoch == mutation, state.isBlocked, !state.isClosed, state.lease == nil else { return nil }
            let lease = DisplayTargetLease(id: UUID(), epoch: mutation, kind: kind)
            state.lease = lease
            return lease
        }
    }
}

/// 可选诊断仅报告已注册的等待，不暴露锁或 continuation。
enum DisplayTargetEvent: Sendable, Equatable {
    /// 这个事务已在旧租约之后排队，可以确定性地制造撤销/归还竞争。
    case waitingForMutation(UUID)
    /// 永久关闭清理正在等待仍持有的平台访问。
    case waitingForClose
}

/// 一段平台访问的身份；只能归还这一份租约，不能释放更新请求的资源。
struct DisplayTargetLease: Sendable, Equatable {
    /// 本次独占访问的唯一身份。
    let id: UUID
    /// 获取时的显示代数；撤销后保留租约直到平台访问结束。
    let epoch: UUID
    /// 区分主层树变更、后台配置和实际绘制，并捕获绘制布局。
    let kind: DisplayAccessKind
}

/// 裸层访问的三类职责，只有绘制携带已经安装的正尺寸几何。
enum DisplayAccessKind: Sendable, Equatable {
    /// 后台 owner 设置 device、格式等渲染属性。
    case configuration
    /// 主 actor 挂载、改变frame/contentsScale或卸载层。
    case mainMutation
    /// 后台读取 drawable 并使用它直到提交完成，关联值是不可变布局。
    case drawing(DisplayGeometry)
}

/// 显示状态诊断与小值传输，不是裸层或纹理句柄。
struct DisplayTargetSnapshot: Sendable {
    /// 当前配置事务/绘制的身份。
    let epoch: UUID
    /// 最后成功发布的宿主配置。
    let configuration: DisplayTargetConfiguration
    /// 正在修改几何/层关系时为 true，此时不得开始绘制。
    let isBlocked: Bool
    /// 已经永久关闭，不能重新挂载或激活。
    let isClosed: Bool
    /// 是否仍有一段平台访问未结束。
    let hasLease: Bool
    /// 当前等待排空的 continuation 数量，仅用于内部诊断。
    let waitingCount: Int
}

/// Mutex 内部状态；平台对象没有存放在这里，避免长系统调用占住值锁。
private struct DisplayMailboxStorage {
    /// 初始不可呈现配置对应的随机身份。
    var epoch = UUID()
    /// 最后发布的配置，初始没有布局且未挂载/激活。
    var configuration = DisplayTargetConfiguration()
    /// 事务期间禁止新绘制；初始无需事务也因配置为空而不能呈现。
    var isBlocked = false
    /// 永久关闭标志，不允许从关闭状态重新激活。
    var isClosed = false
    /// 当前唯一平台访问，nil 表示可进入下一段独占访问。
    var lease: DisplayTargetLease?
    /// 当前事务等旧租约归还的调用者，每个 continuation 只恢复一次。
    var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// 永久关闭时等待剩余租约归还的清理任务。
    var closeWaiters: [CheckedContinuation<Void, Never>] = []
}
