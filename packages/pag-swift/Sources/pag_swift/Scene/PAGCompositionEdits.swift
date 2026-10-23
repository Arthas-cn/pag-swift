/// 每份合成值的 COW 编辑记录；所有缺失条目表示使用原始场景。
struct CompositionEdits: Sendable {
    /// 实例显示覆盖，不能通过源 ID 误改同源的其他预合成实例。
    var visibility: [PAGLayerID: Bool] = [:]
    /// 文件文本槽覆盖；同一源文本的所有实例共同使用一份替换。
    var texts: [Int: PAGText] = [:]
    /// 每个图像实例当前唯一替换；删除键恢复原始素材，不恢复历史覆盖。
    var images: [PAGLayerID: PAGImage] = [:]
    /// 按 tag 替换时显式选择的图片适配；缺失继续使用 PAG 文件规则。
    var imageScaleModes: [PAGLayerID: PAGScaleMode] = [:]
    /// 替换内容独占的静态 alpha 遮罩；来源槽仍保有自己的图层职责。
    var imageMasks: [PAGLayerID: PreparedImageMask] = [:]
    /// 每个图像实例的视频待帧占位；只有正常图片素材可作为占位。
    var placeholders: [PAGLayerID: PAGImage] = [:]
    /// 可编辑文本槽的附加溢出策略，缺失时完整保留PAG原始排版。
    var textOverflows: [Int: PAGTextOverflow] = [:]
}

/// 在完整场景上原子建立编辑覆盖，原始文档与其他快照保持不变。
extension PAGComposition {
    /// 返回允许文本槽的当前覆盖或原始值；索引不在允许集合时抛 invalidEditableIndex。
    public func text(at index: Int) throws -> PAGText {
        guard storage.catalog.textSet.contains(index) else { throw PAGError.invalidEditableIndex(index) }
        return edits.texts[index] ?? storage.catalog.texts[index].style
    }

    /// 修改指定实例的显示开关；不存在或来自其他内容的身份抛 invalidLayer。
    public mutating func setVisibility(_ isVisible: Bool, for id: PAGLayerID) throws {
        guard storage.layerIndices[id] != nil else { throw PAGError.invalidLayer }
        edits.visibility[id] = isVisible
    }

    /// 替换允许文本槽的所有实例，nil 恢复源文字；数值非法时整个快照保持不变。
    public mutating func replaceText(_ text: PAGText?, at index: Int) throws {
        guard storage.catalog.textSet.contains(index) else { throw PAGError.invalidEditableIndex(index) }
        // PAGText 字段可变，构造时通过验证不代表提交时仍然有效；先验证再修改 COW 表。
        try text?.validate()
        if case .marquee? = edits.textOverflows[index],
           let text, text.text.contains(where: { $0.isNewline }) {
            throw PAGError.unsupportedFeature("marqueeMultiline")
        }
        if case .truncate? = edits.textOverflows[index],
           let text, text.text.contains(where: { $0.isNewline }) {
            throw PAGError.unsupportedFeature("truncateMultilineOrVertical")
        }
        edits.texts[index] = text
    }

    /// 指定文本槽的溢出行为；nil恢复源排版，非法槽、非水平框及多行滚动整体拒绝。
    public mutating func setTextOverflow(_ overflow: PAGTextOverflow?, at index: Int) throws {
        guard storage.catalog.textSet.contains(index) else { throw PAGError.invalidEditableIndex(index) }
        if let overflow {
            for (compositionIndex, composition) in storage.compositions.enumerated() {
                for (layerIndex, layer) in composition.layers.enumerated() {
                    let reference = SourceLayerReference(composition: compositionIndex, layer: layerIndex)
                    guard storage.catalog.slots[reference] == index,
                          case .text(let source) = layer.content else { continue }
                    guard source.isBoxText, source.boxSize.x > 0, source.boxSize.y > 0,
                          source.direction != 2, layer.textPath == nil else {
                        throw PAGError.unsupportedFeature("textOverflowLayout")
                    }
                    if case .marquee = overflow {
                        guard !(edits.texts[index] ?? source.style).text.contains(where: { $0.isNewline }) else {
                            throw PAGError.unsupportedFeature("marqueeMultiline")
                        }
                    }
                    if case .truncate = overflow {
                        guard source.direction == 0,
                              !(edits.texts[index] ?? source.style).text.contains(where: { $0.isNewline }) else {
                            throw PAGError.unsupportedFeature("truncateMultilineOrVertical")
                        }
                    }
                }
            }
        }
        edits.textOverflows[index] = overflow
    }

    /// 替换允许图片槽关联的全部实例，并清除先前 tag 的遮罩/适配选项；nil 恢复原始资源。
    public mutating func replaceImage(_ image: PAGImage?, at index: Int) throws {
        guard storage.catalog.imageSet.contains(index) else { throw PAGError.invalidEditableIndex(index) }
        for instance in storage.instances {
            let reference = SourceLayerReference(composition: instance.compositionIndex, layer: instance.layerIndex)
            let source = storage.compositions[instance.compositionIndex].layers[instance.layerIndex]
            if case .image = source.content, storage.catalog.slots[reference] == index {
                edits.images[instance.id] = image
                edits.imageMasks[instance.id] = nil
                edits.imageScaleModes[instance.id] = nil
            }
        }
    }

    /// 替换同名图像并清除其遮罩/适配选项；零匹配抛 noMatchingImageLayer，不影响同名其他层。
    public mutating func replaceImage(_ image: PAGImage?, named name: String) throws {
        let matches = layers(named: name).filter { $0.kind == .image }.map(\.id)
        guard !matches.isEmpty else { throw PAGError.noMatchingImageLayer(name) }
        // 先找到完整集合再提交，避免中途失败只改了一部分；nil 同样表示恢复原图。
        for id in matches {
            edits.images[id] = image
            edits.imageMasks[id] = nil
            edits.imageScaleModes[id] = nil
        }
    }

    /// 为允许编辑的图片槽全部实例设置或清除占位；视频不能作为等待另一段视频的占位。
    public mutating func setPlaceholder(_ image: PAGImage?, at index: Int) throws {
        guard storage.catalog.imageSet.contains(index) else { throw PAGError.invalidEditableIndex(index) }
        guard image?.kind != .video else { throw PAGError.invalidArgument("placeholder") }
        for instance in storage.instances {
            let reference = SourceLayerReference(composition: instance.compositionIndex, layer: instance.layerIndex)
            let source = storage.compositions[instance.compositionIndex].layers[instance.layerIndex]
            if case .image = source.content, storage.catalog.slots[reference] == index {
                edits.placeholders[instance.id] = image
            }
        }
    }

    /// 对名称精确匹配的全部图像实例设置占位；零匹配不改变快照。
    public mutating func setPlaceholder(_ image: PAGImage?, named name: String) throws {
        let matches = layers(named: name).filter { $0.kind == .image }.map(\.id)
        guard !matches.isEmpty else { throw PAGError.noMatchingImageLayer(name) }
        guard image?.kind != .video else { throw PAGError.invalidArgument("placeholder") }
        for id in matches { edits.placeholders[id] = image }
    }

    /// 删除所有覆盖，恢复文件原始文本、素材、占位、溢出策略与显示开关。
    public mutating func resetEdits() {
        edits = CompositionEdits()
    }

    /// 求值层按实例读取当前输入图像；外来 ID 或非图像层返回 nil。
    func image(for id: PAGLayerID) -> PAGImage? {
        guard let index = storage.layerIndices[id] else { return nil }
        if let replacement = edits.images[id] { return replacement }
        let instance = storage.instances[index]
        let source = storage.compositions[instance.compositionIndex].layers[instance.layerIndex]
        guard case .image(let resourceID) = source.content else { return nil }
        return storage.resources.images[resourceID]?.image
    }
}
