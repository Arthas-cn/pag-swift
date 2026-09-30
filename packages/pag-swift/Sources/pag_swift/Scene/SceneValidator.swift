/// 源 DAG 的完整校验入口；图结构通过后才展开公开实例树。
enum SceneValidator {
    /// 验证所有合成、引用、时间和资源上限；失败不返回 PAGFile 或部分图层。
    static func build(compositions: [SourceComposition], identity: DocumentIdentity,
                      limits: PAGLoadLimits, budget: inout DecodeBudget,
                      resources: SourceResources = SourceResources(),
                      fileTiming: SourceFileTiming = SourceFileTiming()) throws -> PAGFile {
        try Task.checkCancellation()
        guard !compositions.isEmpty else { throw invalid("missingComposition") }
        try budget.reserve(count: compositions.count, stride: 512)
        var compositionIndices: [UInt32: Int] = [:]
        var topologies: [CompositionTopology] = []
        var contentKinds: Set<PAGLayerKind> = []
        var sourceCount = 0
        for (index, composition) in compositions.enumerated() {
            try Task.checkCancellation()
            // Composition::verify允许定义ID0；重复定义的上游first-wins尚未实现，必须明确未支持。
            guard compositionIndices.updateValue(index, forKey: composition.id) == nil else {
                throw PAGError.unsupportedFeature("duplicateCompositionID")
            }
            guard composition.layers.count <= limits.maximumLayerCount - sourceCount else {
                throw PAGError.resourceLimitExceeded("maximumLayerCount")
            }
            sourceCount += composition.layers.count
            guard (composition.bitmap == nil && composition.video == nil) || composition.layers.isEmpty,
                  composition.bitmap == nil || composition.video == nil else {
                throw invalid("mixedCompositionContent")
            }
            try budget.reserve(count: composition.layers.count, stride: 256)
            try validateTime(start: 0, duration: composition.durationFrames, rate: composition.frameRate)
            try budget.reserve(count: composition.layers.count, stride: 32)
            topologies.append(try validateLayers(in: composition, resources: resources))
            for layer in composition.layers {
                try Task.checkCancellation()
                contentKinds.insert(layer.content.kind)
            }
        }
        let expandedCounts = try CompositionGraph.validate(compositions, indices: compositionIndices, limits: limits)
        try budget.reserve(count: sourceCount, stride: 128)
        // 新增模式字典至多按源图层数与编码表长度中的较小值增长，在建立配对前预留。
        try budget.reserve(count: min(sourceCount, resources.imageScaleModes?.count ?? 0), stride: 64)
        let catalog = try EditableCatalog.build(compositions: compositions, indices: compositionIndices, resources: resources)
        return try SceneInstances.build(compositions: compositions, compositionIndices: compositionIndices,
                                        identity: identity, expectedCount: expandedCounts[compositions.count - 1], budget: &budget,
                                        resources: resources, catalog: catalog, topologies: topologies,
                                        contentKinds: contentKinds, fileTiming: fileTiming)
    }

    /// 验证同级 ID、父链和每层的可表示时间区间；父链不改变公开子树关系。
    private static func validateLayers(in composition: SourceComposition, resources: SourceResources) throws -> CompositionTopology {
        var indices: [UInt32: Int] = [:]
        for (index, layer) in composition.layers.enumerated() {
            try Task.checkCancellation()
            guard layer.id > 0, indices.updateValue(index, forKey: layer.id) == nil else {
                throw invalid("duplicateOrZeroLayerID")
            }
            try validateTime(start: layer.startFrame, duration: layer.durationFrames, rate: composition.frameRate)
            if layer.imageFillRule != nil, layer.content.kind != .image {
                throw invalid("imageFillRuleInNonImageLayer")
            }
            if case let .precomposition(_, start) = layer.content {
                _ = try time(frame: start, rate: composition.frameRate)
            }
            if case .image(let id) = layer.content, resources.images[id] == nil {
                throw invalid("missingImageReference")
            }
        }
        var parents = Array<Int?>(repeating: nil, count: composition.layers.count)
        for (index, layer) in composition.layers.enumerated() {
            if let id = layer.parentID {
                guard let parent = indices[id] else { throw invalid("missingParentLayer") }
                parents[index] = parent
            }
        }
        // 父链可能比合成深度长得多；用三色迭代检查，不能递归调用消耗 Swift 栈。
        var states = Array(repeating: UInt8(0), count: parents.count)
        for start in parents.indices where states[start] == 0 {
            var path: [Int] = []
            var next: Int? = start
            while let index = next {
                try Task.checkCancellation()
                if states[index] == 2 { break }
                guard states[index] == 0 else { throw invalid("parentLayerCycle") }
                states[index] = 1
                path.append(index)
                next = parents[index]
            }
            for index in path { states[index] = 2 }
        }
        return CompositionTopology(parents: parents)
    }

    /// 验证帧与微秒区间均为正且不溢出；文件错误不能泄漏为调用参数错误。
    private static func validateTime(start: Int64, duration: Int64, rate: Double) throws {
        guard duration > 0, rate.isFinite, rate > 0,
              !start.addingReportingOverflow(duration).overflow else { throw invalid("invalidFrameRange") }
        let startTime = try time(frame: start, rate: rate)
        let durationTime = try time(frame: duration, rate: rate)
        guard durationTime.microseconds > 0,
              !startTime.microseconds.addingReportingOverflow(durationTime.microseconds).overflow else {
            throw invalid("invalidMicrosecondRange")
        }
    }

    /// 将已知帧值转为公开微秒，不能表示的输入报告文件时基错误。
    static func time(frame: Int64, rate: Double) throws -> PAGTime {
        do { return try TimeMapping.time(forFrame: frame, frameRate: rate) }
        catch { throw invalid("unrepresentableTime") }
    }

    /// 创建没有单一字节位置的跨记录验证错误。
    static func invalid(_ reason: String) -> PAGError {
        .invalidFile(reason: reason, offset: nil)
    }
}
