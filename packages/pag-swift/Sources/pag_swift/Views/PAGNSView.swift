#if os(macOS)
import AppKit

/// AppKit显示宿主；只桥接布局、可见性和系统刷新，所有播放与Metal工作由共同核心执行。
@MainActor public final class PAGNSView: NSView {
    /// View坐标中的普通父层，隔离非零bounds原点与实际Metal显示层。
    private let contentLayer = CALayer()
    /// 共享宿主事务协调器；初始化super之后建立，以便刷新闭包弱引用View。
    private var host: DisplayHost?
    /// 即将关闭的窗口身份；willClose时窗口可能仍报告visible，必须提前停用。
    private var closingWindow: ObjectIdentifier?
    /// AppKit通知可能位于窗口属性变更过程中；只保留一次后续主actor采样，读取最终值。
    private var visibilityRefresh: Task<Void, Never>?

    /// 绑定已有播放器，不加载文件、不自动play；设备或挂载失败通过播放器状态报告。
    public init(player: PAGPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        host = DisplayHost(player: player, parent: contentLayer) { [weak self] in
            guard let self else { throw CancellationError() }
            return try PAGSurface { [weak self] refresh in
                DisplayRefreshDriver(factory: { [weak self] target, selector in
                    self?.displayLink(target: target, selector: selector)
                }, refresh: refresh)
            }
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didChangeBackingPropertiesNotification, NSWindow.willCloseNotification,
                     NSWindow.didUpdateNotification] {
            center.addObserver(self, selector: #selector(windowChanged), name: name, object: nil)
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            center.addObserver(self, selector: #selector(applicationChanged), name: name, object: nil)
        }
        updateHost()
    }

    /// 首版仅支持程序化绑定，不从nib恢复隐式播放器。
    @available(*, unavailable, message: "Use init(player:).")
    public required init?(coder: NSCoder) { return nil }

    /// 移除观察者并同步撤销宿主身份；异步GPU排空由协调器负责。
    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        visibilityRefresh?.cancel()
        host?.shutdown()
    }

    /// PAG逻辑坐标以左上角为原点，宿主保持同方向。
    public override var isFlipped: Bool { true }

    /// 保留AppKit管理的backing层生命周期；普通容器作为子层，不把View变成手工layer-hosting模式。
    public override func makeBackingLayer() -> CALayer {
        let backing = CALayer()
        backing.addSublayer(contentLayer)
        return backing
    }

    /// 使用层更新通知，不为透明宿主生成CPU绘图内容。
    public override var wantsUpdateLayer: Bool { true }

    /// 窗口首次显示不一定改变occlusion位，初始层更新也必须重新采样isVisible。
    public override func updateLayer() { updateHost() }

    /// 布局只调整普通容器层，并提交当前完整显示小值。
    public override func layout() { super.layout(); updateHost() }

    /// 直接frame修改也同步撤销旧显示许可，不等下一次布局周期才停旧尺寸提交。
    public override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateHost() }

    /// bounds缩放或零布局变化不重建播放器。
    public override func setBoundsSize(_ newSize: NSSize) { super.setBoundsSize(newSize); updateHost() }

    /// 非零bounds原点只影响容器定位，不改变PAG内容坐标。
    public override func setBoundsOrigin(_ newOrigin: NSPoint) { super.setBoundsOrigin(newOrigin); updateHost() }

    /// 进入新窗口时采样真实像素倍率和可见性；NSView的link随窗口迁移。
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        closingWindow = nil
        updateHost()
        scheduleVisibilityRefresh()
    }

    /// 父视图发生变化后重新判断祖先隐藏状态。
    public override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); updateHost() }

    /// AppKit通知自身或祖先隐藏时冻结自动播放，而不是调用pause覆盖原意图。
    public override func viewDidHide() {
        super.viewDidHide()
        updateHost(forceInactive: true)
        scheduleVisibilityRefresh()
    }

    /// 祖先重新显示后恢复目标可用性，主动pause仍由播放器保留。
    public override func viewDidUnhide() { super.viewDidUnhide(); updateHost(); scheduleVisibilityRefresh() }

    /// Retina倍率或屏幕变化先撤销旧尺寸，再以新倍率更新显示层。
    public override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateHost() }

    /// SwiftUI更新只比较已有播放器身份，不重新创建surface。
    func setPlayer(_ player: PAGPlayer) { host?.setPlayer(player) }

    /// SwiftUI明确拆除时立即关闭；deinit重复调用幂等。
    func dismantle() { visibilityRefresh?.cancel(); visibilityRefresh = nil; host?.shutdown() }

    /// 库的宿主生命周期测试等待实际协调结束，不依赖sleep猜测布局时机。
    func waitUntilSettled() async {
        while let visibilityRefresh { await visibilityRefresh.value }
        await host?.waitUntilSettled()
    }

    /// 只处理当前窗口的通知，旧窗口的迟到关闭不能暂停新窗口。
    @objc private func windowChanged(_ notification: Notification) {
        guard let changed = notification.object as? NSWindow, changed === window else { return }
        if notification.name == NSWindow.willCloseNotification { closingWindow = ObjectIdentifier(changed) }
        updateHost()
        scheduleVisibilityRefresh()
    }

    /// 应用隐藏/恢复影响窗口呈现，但不改变用户的播放意图。
    @objc private func applicationChanged(_ notification: Notification) { updateHost(); scheduleVisibilityRefresh() }

    /// 同步通知先停用旧状态；下一次主actor机会确认orderFront/隐藏调用返回后的最终可见性。
    private func scheduleVisibilityRefresh() {
        guard host != nil, visibilityRefresh == nil else { return }
        visibilityRefresh = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            visibilityRefresh = nil
            if let window, window.isVisible, window.occlusionState.contains(.visible) { closingWindow = nil }
            updateHost()
        }
    }

    /// 主actor只采样尺寸和可见性；真正Metal层修改由surface等待租约退出后执行。
    private func updateHost(forceInactive: Bool = false) {
        guard let host else { return }
        if contentLayer.frame != bounds {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.frame = bounds
            CATransaction.commit()
        }
        let visible = window.map {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
                && closingWindow != ObjectIdentifier($0)
        } ?? false
        host.update(.layout(size: bounds.size, scale: Double(window?.backingScaleFactor ?? 1), isMounted: window != nil,
                            isVisible: !forceInactive && visible && !isHiddenOrHasHiddenAncestor && !NSApplication.shared.isHidden))
    }
}
#endif
