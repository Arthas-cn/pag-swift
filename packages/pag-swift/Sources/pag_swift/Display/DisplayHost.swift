import QuartzCore

/// 三种库宿主共用的MainActor协调器；只管理显示配置和绑定，不管理播放时间。
@MainActor final class DisplayHost {
    /// 宿主自己的普通容器层，不向后台泄漏View或层别名。
    private let parent: CALayer
    /// 创建实际平台刷新源与surface；闭包必须弱捕获View。
    private let makeSurface: @MainActor () throws -> PAGSurface
    /// 最近选择的播放器；nil只表示宿主永久关闭。
    private var player: PAGPlayer?
    /// 当前选择的可同步撤销身份，改变player或关闭时替换/撤销。
    private var token = DisplayHostToken()
    /// 最近完整布局；初始离窗、零布局，不允许呈现。
    private var configuration = DisplayHostConfiguration()
    /// 唯一拥有的surface，建立后在布局与可见性变化之间复用。
    private var surface: PAGSurface?
    /// 最近确实完成绑定的播放器及身份，取消后的清理不能漏掉已经安装的目标。
    private var bound: (player: PAGPlayer, token: DisplayHostToken)?
    /// 当前最新请求身份；每次实质输入变化替换，不使用可回绕序号。
    private var requestID = UUID()
    /// 最新待处理请求；连续布局覆盖它，不创建无界任务队列。
    private var pending: DisplayHostRequest?
    /// 唯一协调循环；操作结束后再取最新请求。
    private var runner: Task<Void, Never>?
    /// 唯一可取消的实际操作；下一操作必须等其真正返回。
    private var operation: Task<Void, any Error>?

    /// 接入已有播放器；异步建立目标，失败由仍有效的宿主身份发布到播放器状态。
    init(player: PAGPlayer, parent: CALayer, makeSurface: @escaping @MainActor () throws -> PAGSurface) {
        self.player = player
        self.parent = parent
        self.makeSurface = makeSurface
        enqueue()
    }

    /// 所有者遗漏显式关闭时仍撤销显示，异步清理只捕获旧目标，不捕获自身或View。
    isolated deinit {
        token.cancel()
        operation?.cancel()
        surface?.suspendForHostUpdate()
        if let surface {
            let bound = bound
            Task {
                if let bound { await bound.player.detach(from: surface, host: bound.token) }
                await surface.detach()
            }
        }
    }

    /// 更新完整布局，小值相等时不重新挂载或重置显示代数。
    func update(_ value: DisplayHostConfiguration) {
        guard player != nil, configuration != value else { return }
        configuration = value
        enqueue()
    }

    /// SwiftUI输入身份改变时复用原生View与surface；相同实例不重复预约。
    func setPlayer(_ value: PAGPlayer) {
        guard player != nil, player !== value else { return }
        token.cancel()
        token = DisplayHostToken()
        player = value
        enqueue()
    }

    /// 销毁/SwiftUI拆除立即撤销身份与提交许可，之后只排空自己拥有的表面。
    func shutdown() {
        guard player != nil else { return }
        token.cancel()
        player = nil
        enqueue()
    }

    /// 生命周期测试或宿主清理可等待已有协调工作完成；不轮询、不等待屏幕刷新。
    func waitUntilSettled() async {
        while let runner { await runner.value }
    }

    /// 只保留最新配置并取消当前操作；同步UI回调返回前已经禁止旧GPU请求进入提交段。
    private func enqueue() {
        requestID = UUID()
        pending = DisplayHostRequest(id: requestID, player: player, token: token, configuration: configuration)
        surface?.suspendForHostUpdate()
        operation?.cancel()
        if runner == nil { runner = Task { await drain() } }
    }

    /// 一个有所有权的循环串行排空操作；短暂保活协调器以完成清理，不反向保活View。
    private func drain() async {
        while let request = pending {
            pending = nil
            let task = Task { try await apply(request) }
            operation = task
            let result = await task.result
            operation = nil
            if case .failure(let error) = result, !(error is CancellationError), requestID == request.id,
               request.token.isValid, let player = request.player {
                await player.reportHostFailure(error as? PAGError ?? .renderingFailure(String(describing: error)), token: request.token)
            }
        }
        runner = nil
    }

    /// 单个完整宿主事务，所有暂停点之后检查取消；实际完成的绑定先记账，再接受取消清理。
    private func apply(_ request: DisplayHostRequest) async throws {
        if let bound, bound.player !== request.player || bound.token !== request.token {
            if let surface { await bound.player.detach(from: surface, host: bound.token) }
            self.bound = nil
        }
        if request.player == nil {
            if let surface { await surface.detach() }
            surface = nil
            return
        }
        try Task.checkCancellation()
        guard let player = request.player, request.token.isValid else { throw CancellationError() }
        if bound == nil { try await player.beginHostRequest(request.token) }
        try Task.checkCancellation()
        if let failure = request.configuration.failure { throw failure }
        if surface == nil { surface = try makeSurface() }
        guard let surface else { throw PAGError.graphicsUnavailable }
        let config = request.configuration
        try await surface.applyHostConfiguration(parent: config.isMounted ? parent : nil,
                                                  geometry: config.geometry, isActive: config.isActive)
        try Task.checkCancellation()
        if bound == nil {
            try await player.attach(to: surface, host: request.token)
            bound = (player, request.token)
        }
        try Task.checkCancellation()
    }
}

/// 原生View计算出的显示小值；不含播放状态，geometry为nil表示当前零/非法布局。
struct DisplayHostConfiguration: Equatable {
    /// 正尺寸及像素倍率，nil时必须停用呈现并保留surface最后合法布局。
    var geometry: DisplayGeometry?
    /// View是否位于实际窗口；false时从父层卸载显示层。
    var isMounted = false
    /// 当前宿主/祖先/窗口是否允许呈现；geometry及mounted仍是额外前提。
    var isActive = false
    /// 正布局无法建立显示几何时的明确错误；普通零尺寸不是失败。
    var failure: PAGError?

    /// 将平台布局转成共同小值；零尺寸停用，非有限值、非法scale及预算超限保留具体失败。
    static func layout(size: CGSize, scale: Double, isMounted: Bool, isVisible: Bool) -> Self {
        var value = Self(isMounted: isMounted)
        if size.width == 0 || size.height == 0 { return value }
        do {
            value.geometry = try DisplayGeometry(size: PAGSize(width: size.width, height: size.height), scale: scale)
            value.isActive = isMounted && isVisible
        } catch { value.failure = error as? PAGError ?? .invalidArgument("displayGeometry") }
        return value
    }
}

/// 一次不可变的主actor配置请求，跨暂停点使用自身身份判断旧工作。
private struct DisplayHostRequest {
    /// 与协调器最新请求匹配时才允许报告操作失败。
    let id: UUID
    /// 目标控制器，nil表示永久关闭后的排空请求。
    let player: PAGPlayer?
    /// 对应选择的宿主身份，旧对象销毁不能影响新的绑定。
    let token: DisplayHostToken
    /// 接受同步UI事件时的完整显示小值。
    let configuration: DisplayHostConfiguration
}
