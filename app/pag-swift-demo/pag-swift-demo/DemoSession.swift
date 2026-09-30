import Foundation
import Observation
import pag_swift

/// 用户命令与快照桥接；两个播放器消费同一不可变合成，不自行实现播放。
@MainActor @Observable final class DemoSession {
    /// SwiftUI面板独占的库播放器，整个窗口生命周期保持身份不变。
    let swiftUIPlayer = PAGPlayer()
    /// 原生面板独占播放器，避免两个宿主争抢同一surface。
    let nativePlayer = PAGPlayer()
    /// 载入期间禁止控制旧合成，防止操作与切文件交错。
    private(set) var isLoading = false
    /// 当前文件是否已安装到两个播放器。
    private(set) var isLoaded = false
    /// 最近实际错误；nil表示当前没有载入或播放错误。
    private(set) var errorMessage: String?
    /// SwiftUI播放器的状态与已提交微秒，仅供展示。
    private(set) var swiftUIStatus = "尚未载入"
    /// 原生播放器的状态与已提交微秒，仅供展示。
    private(set) var nativeStatus = "尚未载入"
    /// 当前载入身份；旧task不能回写新文件的界面状态。
    @ObservationIgnored private var loadID = UUID()
    /// 持有控制任务，连续命令取消并等待旧命令退出。
    @ObservationIgnored private var command: Task<Void, Never>?

    /// 取消尚未完成的控制，不留下无主命令。
    isolated deinit { command?.cancel() }

    /// SwiftUI的task(id:)提供取消；可把全部编辑槽替换为四角色块，库负责后台读盘和解码。
    func load(_ path: String, replacingImages: Bool) async {
        let id = UUID()
        loadID = id
        isLoading = true
        isLoaded = false
        errorMessage = nil
        command?.cancel()
        await command?.value
        defer { if loadID == id { isLoading = false } }
        do {
            try Task.checkCancellation()
            guard let resources = Bundle.main.resourceURL?.appending(path: "PAGSamples/resources") else {
                throw PAGError.invalidArgument("demo resources")
            }
            let file = try await PAGLoader.shared.load(from: resources.appending(path: path))
            var composition = file.composition
            if replacingImages && !file.editableImageIndices.isEmpty {
                let image = try await PAGImage.load(from: resources.appending(path: "media/rgba-corners.png"))
                // 只通过公开编辑合同安装快照；两个宿主共享相同素材，适配和裁剪仍由库完成。
                for index in file.editableImageIndices { try composition.replaceImage(image, at: index) }
            }
            for player in [swiftUIPlayer, nativePlayer] {
                try Task.checkCancellation()
                try await player.setComposition(composition)
                await player.setRepeatCount(0)
            }
            try Task.checkCancellation()
            if loadID == id { isLoaded = true }
        } catch is CancellationError {
            // 切文件或离开界面是正常取消，旧任务不能污染新选择。
        } catch {
            if loadID == id { errorMessage = String(describing: error) }
        }
    }

    /// 两个有界快照流由调用方task共同拥有，视图取消后订阅一起结束。
    func observe() async {
        async let first: Void = observe(swiftUIPlayer, isNative: false)
        async let second: Void = observe(nativePlayer, isNative: true)
        _ = await (first, second)
    }

    /// 串行发送最新用户命令；旧命令实际退出后才开始新命令。
    func perform(_ action: DemoCommand) {
        let previous = command
        previous?.cancel()
        command = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            do {
                for player in [swiftUIPlayer, nativePlayer] {
                    try Task.checkCancellation()
                    switch action {
                    case .play: try await player.play()
                    case .pause: await player.pause()
                    case .rewind: try await player.rewind()
                    case .seek(let progress): try await player.seek(to: PAGProgress(progress))
                    case .scale(let mode): await player.setScaleMode(mode)
                    }
                }
            } catch is CancellationError {
                // 下一条交互已取代当前命令，不把它变成播放失败。
            } catch { errorMessage = String(describing: error) }
        }
    }

    /// 格式化实际快照，不通过观察回调seek或推进时钟。
    private func observe(_ player: PAGPlayer, isNative: Bool) async {
        for await snapshot in await player.snapshots() {
            guard !Task.isCancelled else { return }
            let time = snapshot.presentedTime.map { "\($0.microseconds) μs" } ?? "等待首帧"
            let text = "\(snapshot.state) · \(time)"
            if isNative { nativeStatus = text } else { swiftUIStatus = text }
            if let failure = snapshot.failure { errorMessage = String(describing: failure) }
        }
    }
}

/// 演示支持的用户操作；参数是库已经验证或将验证的小值。
enum DemoCommand: Sendable {
    /// 恢复当前位置的播放意图。
    case play
    /// 暂停并保留当前位置。
    case pause
    /// 回到第一帧并清零完成次数。
    case rewind
    /// 请求0...1的根进度，越界由库报告错误。
    case seek(Double)
    /// 改变合成到显示区域的缩放模式。
    case scale(PAGScaleMode)
}
