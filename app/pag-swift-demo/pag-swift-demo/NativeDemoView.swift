import SwiftUI
import pag_swift

#if os(iOS)
import UIKit

/// 将正式UIKit入口放进演示布局；容器只提供布局与祖先隐藏开关。
struct NativeDemoView: UIViewRepresentable {
    /// 窗口会话持有的固定播放器，容器不创建第二份状态机。
    let player: PAGPlayer
    /// 隐藏直接祖先，检验库能观察自身以外的可见性变化。
    let isContentHidden: Bool

    /// 当前系统原生入口名称，用于区分两个演示面板。
    static var platformName: String { "UIKit" }

    /// 建立普通容器与公开PAGUIView，后续布局由系统autoresizing处理。
    func makeUIView(context: Context) -> NativeDemoContainer { NativeDemoContainer(player: player) }

    /// 只改变祖先可见性，所有呈现许可判断留在库里。
    func updateUIView(_ view: NativeDemoContainer, context: Context) { view.content.isHidden = isContentHidden }

    /// 从SwiftUI树移除时释放原生子视图，让库结束自己的绑定。
    static func dismantleUIView(_ view: NativeDemoContainer, coordinator: ()) {
        for child in view.content.subviews { child.removeFromSuperview() }
    }
}

/// UIKit普通父容器，不提供Metal层、不解码或绘制PAG。
final class NativeDemoContainer: UIView {
    /// 可单独隐藏的中间父视图，尺寸始终填满外层。
    let content = UIView()

    /// 挂入公开宿主；固定player由演示会话保活。
    init(player: PAGPlayer) {
        super.init(frame: .zero)
        content.frame = bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(content)
        let pagView = PAGUIView(player: player)
        pagView.frame = content.bounds
        pagView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.addSubview(pagView)
    }

    /// 演示不从归档隐式创建播放器。
    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }
}
#else
import AppKit

/// 将正式AppKit入口放进演示布局，与UIKit使用相同的库合成与控制。
struct NativeDemoView: NSViewRepresentable {
    /// 窗口会话持有的固定播放器，重算不改变身份。
    let player: PAGPlayer
    /// 原生祖先的隐藏状态，不通过pause模拟。
    let isContentHidden: Bool

    /// 当前系统原生入口名称。
    static var platformName: String { "AppKit" }

    /// 创建普通容器和库宿主，不接触surface或Metal对象。
    func makeNSView(context: Context) -> NativeDemoContainer { NativeDemoContainer(player: player) }

    /// AppKit负责发送祖先可见性事件，由库决定呈现许可。
    func updateNSView(_ view: NativeDemoContainer, context: Context) { view.content.isHidden = isContentHidden }

    /// 显式释放子视图，触发库的宿主清理。
    static func dismantleNSView(_ view: NativeDemoContainer, coordinator: ()) {
        for child in view.content.subviews { child.removeFromSuperview() }
    }
}

/// AppKit普通父容器，只为宿主验收提供布局和隐藏条件。
final class NativeDemoContainer: NSView {
    /// 可隐藏的中间父视图，保持与外层相同尺寸。
    let content = NSView()

    /// 固定播放器由会话持有，实际PAG内容只交给库宿主。
    init(player: PAGPlayer) {
        super.init(frame: .zero)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        let pagView = PAGNSView(player: player)
        pagView.frame = content.bounds
        pagView.autoresizingMask = [.width, .height]
        content.addSubview(pagView)
    }

    /// 演示不从nib恢复隐式播放器。
    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }
}
#endif
