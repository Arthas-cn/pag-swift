#if os(iOS)
import UIKit

/// UIKit显示宿主；主线程只处理界面生命周期，复用共同PAGPlayer/PAGSurface直接显示。
@MainActor public final class PAGUIView: UIView {
    /// 普通父层跟随bounds，Metal层的像素和租约始终由surface管理。
    private let contentLayer = CALayer()
    /// 初始化super之后建立的共同宿主协调器，不创建另一份播放状态。
    private var host: DisplayHost?
    /// willDeactivate早于scene状态改变，用此标志及时禁止提交；didActivate清除。
    private var sceneIsDeactivating = false

    /// 绑定已有播放器，不自动加载或播放；初始化目标失败通过播放器快照报告。
    public init(player: PAGPlayer) {
        super.init(frame: .zero)
        isOpaque = false
        layer.addSublayer(contentLayer)
        host = DisplayHost(player: player, parent: contentLayer) { [weak self] in
            guard let self else { throw CancellationError() }
            return try PAGSurface { [weak self] refresh in
                guard let self else { return DisplayRefreshDriver(factory: { _, _ in nil }, refresh: refresh) }
                return DisplayRefreshDriver(view: self, beforeRefresh: { [weak self] in self?.updateHost() }, refresh: refresh)
            }
        }
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: PAGUIView, _: UITraitCollection) in view.updateHost() }
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification,
                     UIScene.didEnterBackgroundNotification, UIScene.willEnterForegroundNotification,
                     UIScene.didDisconnectNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(sceneChanged), name: name, object: nil)
        }
        updateHost()
    }

    /// 首版不支持storyboard恢复，需要调用方显式提供播放器。
    @available(*, unavailable, message: "Use init(player:).")
    public required init?(coder: NSCoder) { return nil }

    /// 退出观察并立即撤销显示许可；后台清理由共同协调器排空。
    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        host?.shutdown()
    }

    /// 自身隐藏变化立即停用；祖先隐藏由被动UIUpdateLink观察下次UI更新。
    public override var isHidden: Bool { didSet { updateHost() } }

    /// 完全透明的自身不继续呈现；祖先透明度在UI更新时共同检查。
    public override var alpha: CGFloat { didSet { updateHost() } }

    /// 同步尺寸变化先撤销旧代数，不依赖后续异步布局才阻止提交。
    public override var bounds: CGRect { didSet { updateHost() } }

    /// 外部直接修改frame同样更新完整布局，重复值由协调器去重。
    public override var frame: CGRect { didSet { updateHost() } }

    /// UIKit最终布局后采样真实尺寸与显示倍率。
    public override func layoutSubviews() { super.layoutSubviews(); updateHost() }

    /// 窗口/scene更换后重算活动状态；UIUpdateLink自身跟随新屏幕。
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        sceneIsDeactivating = false
        updateHost()
    }

    /// 父级变化会改变隐藏链，不能只检查自己的isHidden。
    public override func didMoveToSuperview() { super.didMoveToSuperview(); updateHost() }

    /// SwiftUI传入新播放器时保留原生View及其surface。
    func setPlayer(_ player: PAGPlayer) { host?.setPlayer(player) }

    /// SwiftUI拆除时显式结束宿主，后续deinit重复关闭幂等。
    func dismantle() { host?.shutdown() }

    /// 生命周期测试等待现有协调事务结束，不轮询屏幕或时钟。
    func waitUntilSettled() async { await host?.waitUntilSettled() }

    /// 只响应当前scene；退出活动状态要在系统更新state之前先撤销显示许可。
    @objc private func sceneChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        if notification.name == UIScene.willDeactivateNotification || notification.name == UIScene.didDisconnectNotification {
            sceneIsDeactivating = true
        } else if notification.name == UIScene.didActivateNotification { sceneIsDeactivating = false }
        updateHost()
    }

    /// 只比较主actor的小值，不求值PAG；无连续播放时仍可被动接收祖先显示变化。
    private func updateHost() {
        guard let host else { return }
        if contentLayer.frame != bounds {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.frame = bounds
            CATransaction.commit()
        }
        var current: UIView? = self
        var visible = !sceneIsDeactivating && window?.windowScene?.activationState == .foregroundActive
        while let view = current {
            if view.isHidden || view.alpha <= 0 { visible = false; break }
            current = view.superview
        }
        host.update(.layout(size: bounds.size, scale: traitCollection.displayScale, isMounted: window != nil, isVisible: visible))
    }
}
#endif
