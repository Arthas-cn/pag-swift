import SwiftUI

/// 双平台演示入口，窗口只展示库的显示宿主与公开控制能力。
@main struct MyApp: App {
    /// 每个窗口持有自己的会话，互不共享可变播放状态。
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 720, height: 940)
    }
}
