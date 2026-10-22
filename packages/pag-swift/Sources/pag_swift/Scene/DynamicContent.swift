import Foundation

/// 动态文字在原 PAG 文本框中的呈现选择；不修改文件字节或源图层时间轴。
public enum DynamicTextLayout: Sendable, Hashable {
    /// 保留原 PAG 框文本的字号适应、断行与对齐。
    case automatic
    /// 单行按实际字体测宽，超出文本框时在尾部显示省略号。
    case truncate
    /// 原字号单行超框时滚动；放得下时仍使用原 PAG 排版。
    case marquee(PAGMarqueeOptions)
}

/// 宿主按唯一图层名或类型化索引 tag 提供的运行时内容，种类由 case 明确表示。
public enum DynamicContent: Sendable {
    /// 用指定文字覆盖可编辑文本槽；空串隐藏本轮目标实例。
    case text(String, layout: DynamicTextLayout)
    /// 用已准备的静图、动图或视频覆盖同名图片层。
    case image(PAGImage)
    /// 请宿主 URL 回调取得图片素材；库不执行网络请求。
    case imageURL(URL)
    /// 隐藏当前 tag 的所有实例，不改变其它图层。
    case hidden
}

/// 把宿主动态内容解析为原有合成编辑，播放及 Metal 路径保持统一。
extension PAGComposition {
    /// 按唯一图层名或 `text:0` / `image:2` 索引别名应用内容；失败时原快照保持不变。
    /// - Parameters:
    ///   - content: 宿主为本轮提供的内容。
    ///   - tag: 唯一已解码图层名或从现有可编辑索引派生的类型化别名。
    ///   - loadImageFromURL: 仅 `.imageURL` 使用的宿主异步回调，可自行接入 SDWebImage。
    public mutating func apply(_ content: DynamicContent, forTag tag: String,
                               loadImageFromURL: (@Sendable (URL) async throws -> PAGImage)? = nil) async throws {
        guard !tag.isEmpty else { throw PAGError.invalidArgument("dynamicTag") }
        let named = layers(named: tag)
        let alias: (PAGLayerKind, Int)?
        if named.isEmpty, tag.hasPrefix("text:"), let index = Int(tag.dropFirst(5)),
           storage.catalog.textSet.contains(index) {
            alias = (.text, index)
        } else if named.isEmpty, tag.hasPrefix("image:"), let index = Int(tag.dropFirst(6)),
                  storage.catalog.imageSet.contains(index) {
            alias = (.image, index)
        } else { alias = nil }
        let matches: [PAGLayer]
        if let (kind, index) = alias {
            matches = storage.instances.indices.compactMap { position in
                let layer = PAGLayer(storage: storage, instanceIndex: position, edits: edits)
                return layer.kind == kind && layer.editableIndex == index ? layer : nil
            }
        } else { matches = named }
        guard !matches.isEmpty else { throw PAGError.invalidArgument("dynamicTag") }
        // 重名若跨不同源槽或不同图层类别，调用方必须改用稳定索引别名。
        guard Set(matches.map(\.kind)).count == 1,
              Set(matches.compactMap(\.editableIndex)).count <= 1 else {
            throw PAGError.invalidArgument("ambiguousDynamicTag")
        }
        try Task.checkCancellation()
        var candidate = self
        switch content {
        case .text(let value, let layout):
            guard matches.allSatisfy({ $0.kind == .text }) else {
                throw PAGError.invalidArgument("dynamicContentKind")
            }
            let indices = Set(matches.compactMap(\.editableIndex))
            guard indices.count > 0, matches.allSatisfy({ $0.editableIndex != nil }),
                  indices.allSatisfy({ storage.catalog.textSet.contains($0) }) else {
                throw PAGError.invalidArgument("dynamicTextSlot")
            }
            if value.isEmpty {
                // 空串不具备字形指标，直接隐藏实例以避免发布无效排版资源。
                for layer in matches { try candidate.setVisibility(false, for: layer.id) }
                break
            }
            for index in indices.sorted() {
                var style = try candidate.text(at: index)
                style.text = value
                try candidate.replaceText(style, at: index)
                switch layout {
                case .automatic: try candidate.setTextOverflow(nil, at: index)
                case .truncate: try candidate.setTextOverflow(.truncate, at: index)
                case .marquee(let options): try candidate.setTextOverflow(.marquee(options), at: index)
                }
            }
            try candidate.restoreSourceVisibility(for: matches)
        case .image(let image):
            guard matches.allSatisfy({ $0.kind == .image }) else {
                throw PAGError.invalidArgument("dynamicContentKind")
            }
            if let (_, index) = alias { try candidate.replaceImage(image, at: index) }
            else { try candidate.replaceImage(image, named: tag) }
            try candidate.restoreSourceVisibility(for: matches)
        case .imageURL(let url):
            guard matches.allSatisfy({ $0.kind == .image }) else {
                throw PAGError.invalidArgument("dynamicContentKind")
            }
            guard let loadImageFromURL else { throw PAGError.invalidArgument("loadImageFromURL") }
            let image = try await loadImageFromURL(url)
            // 异步回调可能在旧选择取消后返回；不发布迟到素材。
            try Task.checkCancellation()
            if let (_, index) = alias { try candidate.replaceImage(image, at: index) }
            else { try candidate.replaceImage(image, named: tag) }
            try candidate.restoreSourceVisibility(for: matches)
        case .hidden:
            for layer in matches { try candidate.setVisibility(false, for: layer.id) }
        }
        try Task.checkCancellation()
        self = candidate
    }

    /// 非隐藏内容恢复文件原有的活动开关，避免一次 `.hidden` 永久压住后续替换。
    private mutating func restoreSourceVisibility(for layers: [PAGLayer]) throws {
        for layer in layers {
            guard let position = storage.layerIndices[layer.id] else { throw PAGError.invalidLayer }
            let instance = storage.instances[position]
            let source = storage.compositions[instance.compositionIndex].layers[instance.layerIndex]
            try setVisibility(source.isActive, for: layer.id)
        }
    }
}
