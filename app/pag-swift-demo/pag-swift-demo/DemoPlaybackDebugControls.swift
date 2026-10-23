import SwiftUI
import pag_swift

/// 与 VAP 控制矩阵对应的 PAG 调试入口；所有操作仍复用页面唯一播放器。
struct DemoPlaybackDebugControls: View {
    /// 资源、播放配置和操作日志均来自当前会话。
    let session: DemoSession

    /// 清空后仍可重新准备，不能把恢复入口一起禁用。
    var body: some View {
        GroupBox("控制矩阵") {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack { sceneControls }
                    VStack(alignment: .leading) { sceneControls }
                }
                HStack {
                    Button("上一帧") { session.stepFrame(-1) }
                    Button("下一帧") { session.stepFrame(1) }
                    Button("回卷并暂停") { session.perform("rewind") { try await $0.rewind() } }
                    Button("重绘当前帧") {
                        session.perform("render") { [session] player in
                            await player.pause()
                            let time = await player.snapshot.position
                            let result = try await player.render(at: time)
                            session.append("renderResult", detail: String(describing: result))
                        }
                    }
                }
                .disabled(!session.isLoaded)
                Text("准备只显示当前帧；逐帧和回卷只改变 PAG 位置。GIF/WebP 的独立进度在暂停时保持，恢复后续播。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("detail.controlMatrix")
    }

    /// 重载明确区分缓存路径，清空同时撤销内容请求，避免迟到 provider 再安装。
    @ViewBuilder private var sceneControls: some View {
        Button("准备（不播放）") { session.reload(autoplay: false) }
        Button("缓存重载并播放") { session.reload() }
        Button("重新解析并播放") { session.reload(policy: .reload) }
        Button("清空并释放") {
            session.perform("clear") { player in
                await player.cancelContentRequests()
                await player.pause()
                try await player.setComposition(nil)
            }
        }
        .disabled(!session.isLoaded)
    }
}
