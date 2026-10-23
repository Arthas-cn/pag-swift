import SwiftUI
import pag_swift

/// 只有显式进入此页才创建两份播放器，复用既有平台宿主自动验收流程。
struct DemoHostLab: View {
    /// 两个宿主加载同一份真实 PAG，但编辑和播放状态互不共享。
    let resource: DemoResource
    /// SwiftUI 显示边界的独立会话。
    @State private var first = DemoSession()
    /// UIKit/AppKit 显示边界的独立会话。
    @State private var second = DemoSession()
    /// 两个宿主是否实际挂入视图树。
    @State private var mounted = true
    /// 原生宿主祖先隐藏状态，用于验证系统可见性通知。
    @State private var nativeHidden = false
    /// 真实布局高度，包括零尺寸验收。
    @State private var height = 220.0
    /// 用户或启动参数开始验收，变化后拥有一个可取消视图任务。
    @State private var requested = DemoHostVerification.isRequested
    /// 每次进入只执行一次验收，结果保留在页面。
    @State private var didRun = false
    /// 当前验收步骤结论，不冒充截图对比。
    @State private var result = "尚未运行"

    /// 明确标识两个显示边界，以及实际挂载、隐藏和尺寸控制。
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("显式双宿主验收").font(.title2.bold())
                Text(resource.id).font(.caption)
                Toggle("挂载", isOn: $mounted)
                Toggle("隐藏原生祖先", isOn: $nativeHidden)
                Button("开始生命周期验收") { requested = true }
                    .disabled(didRun || !first.isLoaded || !second.isLoaded)
                Text(result).textSelection(.enabled)
                if mounted {
                    Text("SwiftUI · \(first.status)")
                    PAGView(player: first.player).frame(height: height).background(.gray.opacity(0.12))
                    Text("\(NativeDemoView.platformName) · \(second.status)")
                    NativeDemoView(player: second.player, isContentHidden: nativeHidden)
                        .frame(height: height).background(.gray.opacity(0.12))
                }
                DemoDiagnosticsView(session: first)
                DemoDiagnosticsView(session: second)
            }
            .padding()
        }
        .navigationTitle("宿主对照")
        .task { await first.run(resource) }
        .task { await second.run(resource) }
        .task(id: requested && first.isLoaded && second.isLoaded) {
            guard requested, first.isLoaded, second.isLoaded, !didRun else { return }
            didRun = true
            result = await DemoHostVerification(swiftUIPlayer: first.player, nativePlayer: second.player,
                setMounted: { mounted = $0 }, setNativeHidden: { nativeHidden = $0 },
                setHeight: { height = $0 }, finalFrameTime: PAGTime(microseconds: 2_000_000)).run()
        }
    }
}
