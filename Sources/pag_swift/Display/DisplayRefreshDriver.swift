import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 主actor上的平台刷新适配；回调只投递小值，不求值、解码或编码Metal。
@MainActor final class DisplayRefreshDriver: NSObject {
    /// 当前平台link；nil表示无可用显示屏或已经终止。
    private var link: CADisplayLink?
    /// 表面提供的轻量回调，必须弱捕获表面以避免runloop保活整个播放器。
    private let refresh: @MainActor () -> Void
    #if os(iOS)
    /// UIKit宿主的系统更新观察器；与CADisplayLink互斥，暂停时只被动观察UI变化。
    private var updateLink: UIUpdateLink?
    #endif

    /// 独立surface默认使用当前显示屏；宿主可提供随窗口迁移的link工厂。
    init(factory: (@MainActor (Any, Selector) -> CADisplayLink?)? = nil,
         refresh: @escaping @MainActor () -> Void) {
        self.refresh = refresh
        super.init()
        if let factory { link = factory(self, #selector(step)) }
        else {
            #if os(macOS)
            _ = NSApplication.shared
            link = NSScreen.main?.displayLink(target: self, selector: #selector(step))
            #else
            link = CADisplayLink(target: self, selector: #selector(step))
            #endif
        }
        link?.isPaused = true
        link?.add(to: .main, forMode: .common)
    }

    /// 是否建立了真实系统link；无屏幕时不能以sleep定时器替代。
    var isAvailable: Bool {
        #if os(iOS)
        link != nil || updateLink != nil
        #else
        link != nil
        #endif
    }

    /// 暂停实际系统通知；暂停不清除已提交画面。
    func setActive(_ active: Bool) {
        link?.isPaused = !active
        #if os(iOS)
        updateLink?.requiresContinuousUpdates = active
        #endif
    }

    /// 解除runloop与target的相互保活；surface销毁必须主动调用，不能只等本对象deinit。
    func invalidate() {
        link?.invalidate()
        link = nil
        #if os(iOS)
        updateLink?.isEnabled = false
        updateLink = nil
        #endif
    }

    #if os(iOS)
    /// UIKit关联到真实View的刷新源；beforeRefresh先检查祖先隐藏，撤销后本次不能再发tick。
    init(view: UIView, beforeRefresh: @escaping @MainActor () -> Void,
         refresh: @escaping @MainActor () -> Void) {
        self.refresh = refresh
        super.init()
        updateLink = UIUpdateLink(view: view) { [weak self] link, _ in
            beforeRefresh()
            // 隐藏会同步停止连续更新；保留被动观察，才能在祖先重新显示后恢复。
            if link.requiresContinuousUpdates { self?.refresh() }
        }
        updateLink?.isEnabled = true
    }
    #endif

    /// 系统主runloop回调，不把CADisplayLink或其平台状态传往控制actor。
    @objc private func step(_ link: CADisplayLink) { refresh() }
}
