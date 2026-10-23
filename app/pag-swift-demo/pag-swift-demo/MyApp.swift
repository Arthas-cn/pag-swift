import SwiftUI

/// 双平台演示入口；macOS固定一个窗口，避免重复验收产生多份独立播放会话。
@main struct MyApp: App {
    /// 启动时固化构建身份，避免运行中再次编译覆盖磁盘标记后误报当前版本。
    init() { _ = DemoEnvironment.current() }

    /// iOS 沿用系统窗口组；macOS 只允许一个承载目录与详情的主窗口。
    var body: some Scene {
        #if os(macOS)
        // WindowGroup允许从“新建窗口”复制播放会话，验收时会误认成多个Demo实例。
        Window("PAG 资源库", id: "main") {
            ContentView()
        }
        .defaultSize(width: 720, height: 940)
        #else
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 720, height: 940)
        #endif
    }
}
