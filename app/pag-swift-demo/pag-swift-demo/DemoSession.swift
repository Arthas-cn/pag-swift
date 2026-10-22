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

    /// SwiftUI的task(id:)提供取消；只给选中的图片槽安装素材，文字走类型化tag入口。
    func load(_ path: String, media: DemoMediaChoice, imageSlot: Int,
              dynamicText: String, textLayout: DemoTextLayout) async {
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
            if media != .original, let index = file.editableImageIndices.contains(imageSlot) ?
                imageSlot : file.editableImageIndices.first {
                let imageURL: URL
                switch media {
                case .original: throw PAGError.invalidArgument("demoMedia")
                case .png: imageURL = resources.appending(path: "media/rgba-corners.png")
                case .gif: imageURL = resources.appending(path: "media/bear.gif")
                case .webp: imageURL = resources.appending(path: "media/webp01.webp")
                case .video: imageURL = resources.appending(path: "game.mp4")
                }
                let placeholder = media == .video ?
                    try await PAGImage.load(from: resources.appending(path: "media/rgba-corners.png")) : nil
                // 同一 PAG 中的三个图层有不同位置和尺寸；全槽替换会叠出多个大小不同的画面。
                let targets = file.composition.layers.filter { $0.editableIndex == index && $0.kind == .image }
                if let tag = targets.first?.name, !tag.isEmpty,
                   file.composition.layers(named: tag).filter({ $0.kind == .image }).count == targets.count {
                    try await composition.apply(.imageURL(imageURL), forTag: tag) { url in
                        if media == .video { return try await PAGImage.loadVideo(from: url) }
                        return try await PAGImage.load(from: url)
                    }
                } else {
                    let image = media == .video ? try await PAGImage.loadVideo(from: imageURL) :
                        try await PAGImage.load(from: imageURL)
                    try composition.replaceImage(image, at: index)
                }
                if path == "editing/ImageDecodeTest.pag" || path == "editing/replace.pag" {
                    // 两份编辑夹具的图片层相互重叠；验收当前槽时隐藏其它层，避免原图盖住动图。
                    for layer in file.composition.layers where layer.kind == .image && layer.editableIndex != index {
                        try composition.setVisibility(false, for: layer.id)
                    }
                }
                if let placeholder { try composition.setPlaceholder(placeholder, at: index) }
            }
            if !dynamicText.isEmpty, let index = file.editableTextIndices.first {
                let name = file.composition.layers.first(where: {
                    $0.editableIndex == index && $0.kind == .text
                })?.name ?? ""
                let tag = name.isEmpty ? "text:\(index)" : name
                let layout: DynamicTextLayout = switch textLayout {
                case .original: .automatic
                case .automatic: .automatic
                case .truncate: .truncate
                case .marquee: .marquee(try PAGMarqueeOptions(speed: 45, gap: 24))
                }
                if textLayout != .original {
                    try await composition.apply(.text(dynamicText, layout: layout), forTag: tag)
                }
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

/// Demo 逐项展示动态文本合同，原始选项不替换 PAG 源文字。
enum DemoTextLayout: String, CaseIterable, Hashable {
    /// 不编辑文字或附加溢出行为。
    case original
    /// 使用源文本框自动字号规则。
    case automatic
    /// 单行超框时显示省略号。
    case truncate
    /// 原字号超框时在文本框内滚动。
    case marquee

    /// 选择器中向用户解释实际呈现行为。
    var title: String {
        switch self {
        case .original: "原始文字"
        case .automatic: "自动字号"
        case .truncate: "尾部截断"
        case .marquee: "跑马灯"
        }
    }
}

/// 现有Demo的单一图片槽替换来源；两个宿主始终消费同一选择。
enum DemoMediaChoice: String, CaseIterable, Hashable, Sendable {
    /// 使用原始PAG内嵌素材。
    case original
    /// 使用静态PNG核对单帧替换。
    case png
    /// 使用多帧GIF核对逐帧显示。
    case gif
    /// 使用动画WebP核对系统逐帧能力。
    case webp
    /// 使用静音MP4核对系统NV12输入与占位。
    case video

    /// 供同一个样例选择器显示的中文名称。
    var title: String {
        switch self {
        case .original: "原始素材"
        case .png: "静态 PNG"
        case .gif: "动画 GIF"
        case .webp: "动画 WebP"
        case .video: "MP4 视频"
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
