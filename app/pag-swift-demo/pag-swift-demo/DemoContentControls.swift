import Foundation
import pag_swift

/// Demo 可选文本布局，全部由库在原 PAG 图层内完成。
nonisolated enum DemoTextLayout: String, CaseIterable, Identifiable, Sendable {
    /// 使用原文本框的自动字号策略。
    case automatic = "自动字号"
    /// 超框时显示尾部省略号。
    case truncate = "尾部截断"
    /// 只有溢出时在原框内滚动。
    case marquee = "跑马灯"
    /// 选择器稳定身份。
    var id: String { rawValue }
    /// 将宿主选择映射成库的类型化布局，不重写文字计算。
    func layout() throws -> DynamicTextLayout {
        switch self {
        case .automatic: .automatic
        case .truncate: .truncate
        case .marquee: .marquee(try PAGMarqueeOptions(speed: 45, gap: 24))
        }
    }
}

/// 明确由宿主加载的图片选项；格式不是 PAG 槽位身份。
nonisolated enum DemoMediaChoice: String, CaseIterable, Identifiable, Sendable {
    /// 单张 PNG，用于验证静图语义。
    case png = "静图 PNG"
    /// 多帧 GIF，实际经 SDWebImage 读取。
    case gif = "GIF · SDWebImage"
    /// 动画 WebP，实际经 SDWebImageWebPCoder 读取。
    case webp = "WebP · SDWebImage"
    /// 选择器稳定身份。
    var id: String { rawValue }
    /// 可复制到报告中的真实替换素材相对路径。
    var path: String {
        switch self {
        case .png: "media/rgba-corners.png"
        case .gif: "media/bear.gif"
        case .webp: "media/webp01.webp"
        }
    }
    /// 宿主负责来源与解码；动图不能经过只返回首帧的图片转换。
    @concurrent func load(root: URL) async throws -> PAGImage {
        let url = root.appending(path: path)
        switch self {
        case .png: return try await PAGImage.load(from: url)
        case .gif, .webp: return try await DemoSDWebImage.load(from: url)
        }
    }
}

/// 普通业务内容示例：只依赖查询到的 tag，不选择 editableIndex 或改变其它图层可见性。
extension DemoSession {
    /// 单槽文字提交，保留 PAG 原字体、样式和图层关系。
    func replaceText(tag: String, text: String, layout: DemoTextLayout) {
        perform("replaceText", tag: tag, detail: "\(layout.rawValue) · \(text)") { player in
            try await player.updateContent(.text(text, layout: layout.layout()), forTag: tag)
        }
    }

    /// 明确异步读取本地宿主素材；默认占位 unchanged，失败时原内容仍可播放。
    func replaceImage(tag: String, choice: DemoMediaChoice, playbackMode: PAGImagePlaybackMode = .animated,
                      scale: DemoImageScaleChoice = .file, mask: DemoImageMaskChoice = .none, maskSource: String = "") {
        perform("replaceImage", tag: tag,
                detail: "\(choice.path) · \(playbackMode) · \(scale.rawValue) · \(mask.rawValue) · \(maskSource)") { player in
            guard let root = DemoResourceCatalog.root else { throw PAGError.invalidArgument("demoResources") }
            try await player.resolveContent(forTag: tag) { _ in
                .image(try await choice.load(root: root), options: .init(playbackMode: playbackMode,
                    scaleMode: scale.mode, mask: try await mask.mask(root: root, sourceTag: maskSource)))
            }
        }
    }

    /// 同时为全部真实源槽返回类型化内容，验证跨 tag 完成不会覆盖已应用的其它编辑。
    func applyMultipleSlots() {
        perform("provider", detail: "所有文字=跑马灯；图片轮换 PNG/GIF/WebP") { player in
            guard let root = DemoResourceCatalog.root else { throw PAGError.invalidArgument("demoResources") }
            let imageTags = await player.contentSlots.filter { $0.kind == .image }.map(\.tag)
            let choices = Dictionary(uniqueKeysWithValues: zip(imageTags, imageTags.indices.map {
                DemoMediaChoice.allCases[$0 % DemoMediaChoice.allCases.count]
            }))
            try await player.setContentProvider { slot in
                if slot.kind == .text {
                    return .text("\(slot.tag) · " + String(repeating: "PAG Swift 动态文字 ", count: 8),
                                 layout: .marquee(try PAGMarqueeOptions(speed: 45, gap: 24)))
                }
                guard let choice = choices[slot.tag] else { return .unchanged }
                return .image(try await choice.load(root: root))
            }
        }
    }

    /// 仅目标槽隐藏或恢复；恢复全部也由槽位目录逐 tag 发出，不遍历层实例。
    func restore(tag: String? = nil, hidden: Bool = false) {
        perform(hidden ? "hide" : "restore", tag: tag) { player in
            let tags = if let tag { [tag] } else { await player.contentSlots.map(\.tag) }
            for tag in tags { try await player.updateContent(hidden ? .hidden : .original, forTag: tag) }
        }
    }
}
