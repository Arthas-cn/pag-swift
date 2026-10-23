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

/// 宿主按槽位目录中的 tag 提供运行时内容，种类由 case 明确表示。
public enum DynamicContent: Sendable {
    /// 不提供覆盖，保持当前内容；初次加载时保留文件原始内容。
    case unchanged
    /// 清除此槽的内容、布局、占位及可见性覆盖，恢复文件原始内容。
    case original
    /// 用指定文字覆盖可编辑文本槽；空串隐藏本轮目标实例。
    case text(String, layout: DynamicTextLayout)
    /// 用已准备素材覆盖源槽的全部实例；默认保留动态属性，options 可明确只显示图像首帧。
    case image(PAGImage, options: PAGImageContentOptions = .standard)
    /// 请宿主 URL 回调取得素材并应用 options；库不执行网络请求。
    case imageURL(URL, options: PAGImageContentOptions = .standard)
    /// 隐藏当前 tag 的所有实例，不改变其它图层。
    case hidden
}

/// 把宿主动态内容解析为原有合成编辑，播放及 Metal 路径保持统一。
extension PAGComposition {
    /// 按 contentSlots 返回的唯一 tag 应用内容；失败时原快照保持不变。
    /// - Parameters:
    ///   - content: 宿主为本轮提供的内容。
    ///   - tag: 槽位目录返回的稳定业务键；不可达或类型错误时保持原快照。
    ///   - loadImageFromURL: 仅 `.imageURL` 使用的宿主异步回调，可自行接入 SDWebImage。
    public mutating func apply(_ content: DynamicContent, forTag tag: String,
                               loadImageFromURL: (@Sendable (URL) async throws -> PAGImage)? = nil) async throws {
        guard let record = dynamicSlotRecords().first(where: { $0.slot.tag == tag }) else {
            throw PAGError.invalidArgument("dynamicTag")
        }
        let matches = record.instances.map { PAGLayer(storage: storage, instanceIndex: $0, edits: edits) }
        try Task.checkCancellation()
        var candidate = self
        switch content {
        case .unchanged: return
        case .original:
            let index = record.slot.sourceIndex
            if record.slot.kind == .text {
                candidate.edits.texts[index] = nil
                candidate.edits.textOverflows[index] = nil
            }
            for layer in matches {
                candidate.edits.images[layer.id] = nil
                candidate.edits.imageMasks[layer.id] = nil
                candidate.edits.imageScaleModes[layer.id] = nil
                candidate.edits.placeholders[layer.id] = nil
                candidate.edits.visibility[layer.id] = nil
            }
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
                // 新布局与新文字一起验证；旧跑马灯不能阻止切回允许多行的自动布局。
                try candidate.setTextOverflow(nil, at: index)
                try candidate.replaceText(style, at: index)
                switch layout {
                case .automatic: try candidate.setTextOverflow(nil, at: index)
                case .truncate: try candidate.setTextOverflow(.truncate, at: index)
                case .marquee(let options): try candidate.setTextOverflow(.marquee(options), at: index)
                }
            }
            try candidate.restoreSourceVisibility(for: matches)
        case .image(let image, let options):
            guard matches.allSatisfy({ $0.kind == .image }) else {
                throw PAGError.invalidArgument("dynamicContentKind")
            }
            try await candidate.applyImage(image, options: options, record: record)
            try candidate.restoreSourceVisibility(for: matches)
        case .imageURL(let url, let options):
            guard matches.allSatisfy({ $0.kind == .image }) else {
                throw PAGError.invalidArgument("dynamicContentKind")
            }
            guard let loadImageFromURL else { throw PAGError.invalidArgument("loadImageFromURL") }
            let image = try await loadImageFromURL(url)
            // 异步回调可能在旧选择取消后返回；不发布迟到素材。
            try Task.checkCancellation()
            try await candidate.applyImage(image, options: options, record: record)
            try candidate.restoreSourceVisibility(for: matches)
        case .hidden:
            for layer in matches { try candidate.setVisibility(false, for: layer.id) }
        }
        try Task.checkCancellation()
        self = candidate
    }

    /// 先准备完整遮罩再一起发布图像及选项；失败不留下部分覆盖或影响遮罩来源槽。
    private mutating func applyImage(_ image: PAGImage, options: PAGImageContentOptions,
                                    record: DynamicSlotRecord) async throws {
        let input = try options.image(from: image)
        let mask: PreparedImageMask?
        if let requested = options.mask, let size = record.slot.size {
            mask = try await PreparedImageMask.prepare(requested, for: size, in: self)
        } else { mask = nil }
        try Task.checkCancellation()
        try replaceImage(input, at: record.slot.sourceIndex)
        for index in record.instances {
            let id = storage.instances[index].id
            edits.imageScaleModes[id] = options.scaleMode
            edits.imageMasks[id] = mask
        }
    }

    /// 非隐藏内容恢复文件原有的活动开关，避免一次 `.hidden` 永久压住后续替换。
    private mutating func restoreSourceVisibility(for layers: [PAGLayer]) throws {
        for layer in layers {
            // 删除覆盖而非强制 true，文件本来禁用的图层仍按源状态显示。
            edits.visibility[layer.id] = nil
        }
    }
}
