import SwiftUI

/// SwiftUI显示宿主，按平台复用原生库View；不会在body重算时创建播放器或解码资源。
@MainActor public struct PAGView: View {
    /// 调用方持有的播放控制器；显示宿主只绑定其身份，不维护镜像播放状态。
    private let player: PAGPlayer

    /// 绑定已有播放器，布局和窗口生命周期由同一原生宿主管理。
    public init(player: PAGPlayer) { self.player = player }

    /// 平台表示层直接显示共同Metal目标，不在SwiftUI中绘制PAG内容。
    public var body: some View { PAGPlatformView(player: player) }
}

#if os(iOS)
/// UIKit表示层；SwiftUI重算只传递播放器身份，拆除交由原生宿主清理。
@MainActor private struct PAGPlatformView: UIViewRepresentable {
    /// 当前父View注入的控制器，每次update直接使用最新值。
    let player: PAGPlayer

    /// 第一次建立库宿主；不会自动创建另一播放器。
    func makeUIView(context: Context) -> PAGUIView { PAGUIView(player: player) }

    /// 相同player由宿主幂等处理，更新不重建目标或播放时钟。
    func updateUIView(_ view: PAGUIView, context: Context) { view.setPlayer(player) }

    /// 显式结束旧绑定，迟到清理不能解绑新宿主。
    static func dismantleUIView(_ view: PAGUIView, coordinator: ()) { view.dismantle() }
}
#else
/// AppKit表示层，与UIKit表示层消费同一个PAGPlayer和显示合同。
@MainActor private struct PAGPlatformView: NSViewRepresentable {
    /// 父View注入的控制器，不通过State保存可能过期的输入。
    let player: PAGPlayer

    /// 首次建立AppKit库宿主，设备失败由播放器状态报告。
    func makeNSView(context: Context) -> PAGNSView { PAGNSView(player: player) }

    /// 身份变化才重绑，不因body重算重建surface。
    func updateNSView(_ view: PAGNSView, context: Context) { view.setPlayer(player) }

    /// 从SwiftUI树移除时撤销旧宿主自己的绑定与显示许可。
    static func dismantleNSView(_ view: PAGNSView, coordinator: ()) { view.dismantle() }
}
#endif
