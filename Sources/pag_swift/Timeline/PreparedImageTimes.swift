/// 安装时准备的图片实例时钟；同源文档的编辑快照共享，不含可变采样游标或媒体解码器。
final class PreparedImageTimes: Sendable {
    /// 每个image实例独立的根时间映射，保留共享预合成的不同偏移。
    let mappings: [PAGLayerID: ImageTimeMapping]
    /// 包含准备暂存与祖先遍历的保守计费，复用时仍受调用方预算约束。
    let estimatedBytes: Int

    /// 仅保存完整准备的结果；取消或失败时不构造可发布对象。
    private init(mappings: [PAGLayerID: ImageTimeMapping], estimatedBytes: Int) {
        self.mappings = mappings
        self.estimatedBytes = estimatedBytes
    }

    /// 从已验证实例树建立父索引与全部图片时钟；非图片场景不分配父表，遍历及数组增长检查预算与取消。
    static func prepare(_ storage: DocumentStorage, budget: inout FramePlanBudget) throws -> PreparedImageTimes {
        try Task.checkCancellation()
        guard storage.contentKinds.contains(.image) else { return PreparedImageTimes(mappings: [:], estimatedBytes: 0) }
        let before = budget.used
        try budget.reserve(count: storage.instances.count, stride: 32)
        var parents = Array<Int?>(repeating: nil, count: storage.instances.count)
        for (index, instance) in storage.instances.enumerated() {
            try Task.checkCancellation()
            for child in instance.children {
                try Task.checkCancellation()
                parents[child] = index
            }
        }
        let root = storage.compositions[storage.rootIndex]
        var mappings: [PAGLayerID: ImageTimeMapping] = [:]
        for (index, instance) in storage.instances.enumerated() {
            try Task.checkCancellation()
            let source = storage.compositions[instance.compositionIndex]
            let layer = source.layers[instance.layerIndex]
            guard case .image = layer.content else { continue }
            try budget.reserve(stride: 256)
            var start = layer.startFrame
            var end = try ImageTimeMath.add(start, layer.durationFrames - 1)
            var rate = source.frameRate
            var ancestor = parents[index]
            while let parentIndex = ancestor {
                try Task.checkCancellation()
                // 逻辑工作也计费，极深共享实例不能绕过准备期预算形成无界祖先扫描。
                try budget.reserve(stride: 32)
                let parent = storage.instances[parentIndex]
                let composition = storage.compositions[parent.compositionIndex]
                guard case .precomposition(_, let offset) = composition.layers[parent.layerIndex].content else {
                    throw SceneValidator.invalid("invalidImageTimelineOwner")
                }
                start = try parentFrame(start, childRate: rate, parentRate: composition.frameRate, offset: offset)
                end = try parentFrame(end, childRate: rate, parentRate: composition.frameRate, offset: offset)
                rate = composition.frameRate
                ancestor = parents[parentIndex]
            }
            // getVisibleRangeInFile连rootFile自身也调用childFrameToLocal；比率1仍会发生Float量化。
            start = try parentFrame(start, childRate: root.frameRate, parentRate: root.frameRate, offset: 0)
            end = try parentFrame(end, childRate: root.frameRate, parentRate: root.frameRate, offset: 0)
            mappings[instance.id] = try ImageTimeMapping.make(layer: layer, visibleStart: start, visibleEnd: end,
                                                               fileDuration: root.durationFrames, budget: &budget)
        }
        try Task.checkCancellation()
        return PreparedImageTimes(mappings: mappings, estimatedBytes: budget.used - before)
    }

    /// 按PAGComposition::childFrameToLocal的源帧率合同映射祖先，不把元数据区间钳到子帧范围。
    private static func parentFrame(_ frame: Int64, childRate: Double, parentRate: Double, offset: Int64) throws -> Int64 {
        let ratio = Float(parentRate) / Float(childRate)
        guard ratio.isFinite, ratio > 0 else { throw SceneValidator.invalid("unrepresentableImageTime") }
        let mapped = (Float(frame) * ratio).rounded(.toNearestOrAwayFromZero)
        guard let value = Int64(exactly: mapped) else { throw SceneValidator.invalid("unrepresentableImageTime") }
        return try ImageTimeMath.add(value, offset)
    }
}
