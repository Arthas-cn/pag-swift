/// 内容Picture与额外Vector Picture的源条件；不代表GPU已建立或命中快照。
struct PictureCandidates: Sendable {
    /// 与源定义及其原始层索引对齐；true只表示Auto策略会请求层内容包装。
    let layerContent: [[Bool]]
    /// 与源定义索引对齐；true只表示Vector渲染器会请求额外包装。
    let vector: [Bool]
    /// 全部原始子层的递归图片内容标记；不可按当前可见性缩窄。
    let hasImageContent: [Bool]

    /// 从已验证源定义和③b范围建立候选表；取消或预算失败不返回部分结果。
    static func make(compositions: [SourceComposition], indices: [UInt32: Int],
                     vectorRanges: [StaticFrameRanges], budget: inout FramePlanBudget) throws -> Self {
        try Task.checkCancellation()
        guard vectorRanges.count == compositions.count else { throw SceneValidator.invalid("pictureRangeCount") }
        try budget.reserve(count: compositions.count, stride: 96)
        var states = Array(repeating: UInt8(0), count: compositions.count)
        var images = Array<Bool?>(repeating: nil, count: compositions.count)
        var masks = Array<Bool?>(repeating: nil, count: compositions.count)
        for start in compositions.indices where states[start] == 0 {
            var stack: [(index: Int, exiting: Bool)] = [(start, false)]
            while let entry = stack.popLast() {
                try visit(budget: &budget)
                let index = entry.index
                if entry.exiting {
                    let flags = try contentFlags(in: compositions[index], compositions: compositions,
                                                 indices: indices, images: images, masks: masks, budget: &budget)
                    images[index] = flags.image
                    masks[index] = flags.mask
                    states[index] = 2
                    continue
                }
                if states[index] == 2 { continue }
                guard states[index] == 0 else { throw SceneValidator.invalid("compositionCycle") }
                states[index] = 1
                stack.append((index, true))
                // 后序必须先分析全部引用，包括隐藏层及根不可达定义。
                for layer in compositions[index].layers.reversed() {
                    try visit(budget: &budget)
                    guard case let .precomposition(id, _) = layer.content else { continue }
                    guard id > 0, let child = indices[id], compositions.indices.contains(child) else {
                        throw SceneValidator.invalid("missingCompositionReference")
                    }
                    if states[child] == 1 { throw SceneValidator.invalid("compositionCycle") }
                    if states[child] == 0 { stack.append((child, false)) }
                }
            }
        }
        var layers: [[Bool]] = []
        var vectors: [Bool] = []
        var imageValues: [Bool] = []
        for (index, source) in compositions.enumerated() {
            try visit(budget: &budget)
            guard let hasImage = images[index], let hasMask = masks[index] else {
                throw SceneValidator.invalid("missingPictureContentFlags")
            }
            imageValues.append(hasImage)
            try budget.reserve(count: source.layers.count, stride: 16)
            var content: [Bool] = []
            for layer in source.layers {
                try visit(budget: &budget)
                switch layer.content {
                case .shape:
                    // Auto只看内容局部静态，外层Transform变化不改变本层内容的候选资格。
                    let staticContent = try ShapeContentRanges.make(for: layer, budget: &budget)
                    let complete = try staticContent.covers(startFrame: 0, duration: layer.durationFrames)
                    content.append(layer.durationFrames > 1 && complete)
                case .text(let source):
                    // 动画器逐帧改变glyph矩阵/alpha，静态Picture身份不能复用旧帧。
                    content.append(layer.durationFrames > 1 && layer.textPath == nil
                                   && layer.textAnimators.isEmpty && source.backgroundAlpha == 0)
                case .null, .solid, .image, .precomposition:
                    content.append(false)
                }
            }
            layers.append(content)
            let isVector = source.bitmap == nil && source.video == nil
            let complete = try vectorRanges[index].covers(startFrame: 0, duration: source.durationFrames)
            // 此阶段尚不能把子mask重映到Vector局部纹理；关闭可选快照不改变原逐draw画面。
            vectors.append(isVector && source.layers.count > 1 && !hasImage && !hasMask
                           && complete)
        }
        return Self(layerContent: layers, vector: vectors, hasImageContent: imageValues)
    }

    /// 图片遵从上游hasImageContent；蒙版保守关闭尚不支持局部重映射的Vector快照。
    private static func contentFlags(in source: SourceComposition, compositions: [SourceComposition],
                                     indices: [UInt32: Int], images: [Bool?], masks: [Bool?],
                                     budget: inout FramePlanBudget) throws -> (image: Bool, mask: Bool) {
        var hasImage = source.bitmap != nil || source.video != nil
        var hasMask = false
        for (index, layer) in source.layers.enumerated() {
            try visit(budget: &budget)
            // 编码首层无轨道遮罩引用；其余层的双输入局部效果不能缓存成普通Vector定义。
            hasMask = hasMask || !layer.masks.isEmpty || layer.textPath != nil || !layer.dropShadows.isEmpty
                || (index > 0 && layer.trackMatte != .none)
            switch layer.content {
            case .image:
                hasImage = true
            case .precomposition(let id, _):
                guard id > 0, let child = indices[id], compositions.indices.contains(child),
                      let childHasImage = images[child], let childHasMask = masks[child] else {
                    throw SceneValidator.invalid("missingCompositionReference")
                }
                hasImage = hasImage || childHasImage
                hasMask = hasMask || childHasMask
            case .null, .solid, .shape, .text:
                break
            }
        }
        return (hasImage, hasMask)
    }

    /// 逐个图节点、边、层访问前收费并响应取消，不在结果形成前发布缓存状态。
    private static func visit(budget: inout FramePlanBudget) throws {
        try Task.checkCancellation()
        try budget.reserve(stride: 32)
    }
}
