/// 源图层的结构身份，不同合成中的相同编码 ID 仍是不同记录。
struct SourceLayerReference: Sendable, Hashable {
    /// 合成在文档源数组中的下标。
    let composition: Int
    /// 图层在其合成编码顺序中的下标。
    let layer: Int
}

/// 文件编辑槽和允许索引集合；不保存任何用户编辑覆盖。
struct EditableCatalog: Sendable {
    /// 编码顺序 DFS 中首次出现的原始文本，每个源图层只记一次。
    let texts: [SourceText]
    /// 编码顺序 DFS 中首次出现的图片资源 ID，同资源共享一槽。
    let imageIDs: [UInt32]
    /// 源层到自身类型编辑槽的映射；非文本/图像源层没有条目。
    let slots: [SourceLayerReference: Int]
    /// 升序且无重复的允许文本索引。
    let allowedTexts: [Int]
    /// 升序且无重复的允许图片索引。
    let allowedImages: [Int]
    /// 允许文本索引的常数时间成员查询。
    let textSet: Set<Int>
    /// 允许图片索引的常数时间成员查询。
    let imageSet: Set<Int>
    /// 文件源图片槽的替换缩放方式；未配对的槽按aspectFit处理，不按此字典授予编辑权限。
    let imageScaleModes: [Int: PAGScaleMode]

    /// 图已完成引用和循环验证；此处严格按 File.cpp::updateEditables 的编码顺序建立槽。
    static func build(compositions: [SourceComposition], indices: [UInt32: Int],
                      resources: SourceResources) throws -> EditableCatalog {
        let root = compositions.count - 1
        var seen: Set<Int> = [root]
        var stack = [(composition: root, layer: 0)]
        var texts: [SourceText] = []
        var imageIDs: [UInt32] = []
        var imageSlots: [UInt32: Int] = [:]
        var slots: [SourceLayerReference: Int] = [:]
        while !stack.isEmpty {
            try Task.checkCancellation()
            let current = stack[stack.count - 1]
            if current.layer == compositions[current.composition].layers.count {
                stack.removeLast()
                continue
            }
            stack[stack.count - 1].layer += 1
            let reference = SourceLayerReference(composition: current.composition, layer: current.layer)
            switch compositions[current.composition].layers[current.layer].content {
            case .text(let text):
                slots[reference] = texts.count
                texts.append(text)
            case .image(let id):
                if let slot = imageSlots[id] { slots[reference] = slot }
                else {
                    let slot = imageIDs.count
                    imageIDs.append(id)
                    imageSlots[id] = slot
                    slots[reference] = slot
                }
            case .precomposition(let id, _):
                guard let child = indices[id] else { throw SceneValidator.invalid("missingCompositionReference") }
                // 已见合成只重复实例，不产生新的文本源记录或图片分组；无需指数遍历。
                if seen.insert(child).inserted { stack.append((child, 0)) }
            default: break
            }
        }
        let allowedTexts = try allowed(resources.allowedTexts, count: texts.count)
        let allowedImages = try allowed(resources.allowedImages, count: imageIDs.count)
        var imageScaleModes: [Int: PAGScaleMode] = [:]
        // 源码按原始editableImages中的位置取模式；公开排序只用于展示，不能重排这组配对。
        for (slot, mode) in zip(resources.allowedImages ?? allowedImages, resources.imageScaleModes ?? []) {
            try Task.checkCancellation()
            imageScaleModes[slot] = mode
        }
        return EditableCatalog(texts: texts, imageIDs: imageIDs, slots: slots, allowedTexts: allowedTexts,
                               allowedImages: allowedImages, textSet: Set(allowedTexts), imageSet: Set(allowedImages),
                               imageScaleModes: imageScaleModes)
    }

    /// 常数时间取得源图层的文件替换模式；未关联允许槽或缺少配对模式时使用上游LetterBox默认。
    func imageScaleMode(for source: SourceLayerReference) -> PAGScaleMode {
        guard let slot = slots[source] else { return .aspectFit }
        return imageScaleModes[slot] ?? .aspectFit
    }

    /// 缺失列表开放全部槽；显式空列表保持空，非法或重复索引按文件错误拒绝。
    private static func allowed(_ indices: [Int]?, count: Int) throws -> [Int] {
        guard let indices else { return Array(0..<count) }
        guard indices.allSatisfy({ (0..<count).contains($0) }), Set(indices).count == indices.count else {
            throw SceneValidator.invalid("invalidEditableIndices")
        }
        return indices.sorted()
    }
}
