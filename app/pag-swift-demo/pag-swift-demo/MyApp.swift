import SwiftUI

/// 双平台演示入口；macOS固定一个窗口，避免重复验收产生多份独立播放会话。
@main struct MyApp: App {
    /// iOS沿用系统窗口组；macOS只允许一个承载双宿主对照的主窗口。
    var body: some Scene {
        #if os(macOS)
        // WindowGroup允许从“新建窗口”复制播放会话，验收时会误认成多个Demo实例。
        Window("PAG Swift 播放验证", id: "main") {
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
