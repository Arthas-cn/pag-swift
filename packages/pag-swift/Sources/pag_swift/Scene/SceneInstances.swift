/// 将已经通过预算与无环检查的源 DAG 建成只含索引的公开实例树。
enum SceneInstances {
    /// 按上游 PAGFile::BuildPAGLayer 的逆编码顺序前序展开；资源仍只存于源合成。
    static func build(compositions: [SourceComposition], compositionIndices: [UInt32: Int],
                      identity: DocumentIdentity, expectedCount: Int,
                      budget: inout DecodeBudget, resources: SourceResources, catalog: EditableCatalog,
                      topologies: [CompositionTopology], contentKinds: Set<PAGLayerKind>,
                      fileTiming: SourceFileTiming) throws -> PAGFile {
        // 此成本覆盖实例值、直接子数组、反向字典和构造期栈；路径长度另行计费。
        try budget.reserve(count: expectedCount, stride: 512)
        let rootIndex = compositions.count - 1
        var stack = [ExpansionFrame(compositionIndex: rootIndex, nextLayer: compositions[rootIndex].layers.count - 1,
                                    parent: nil, path: [])]
        var instances: [LayerInstance] = []
        var roots: [Int] = []
        var lookup: [PAGLayerID: Int] = [:]
        instances.reserveCapacity(expectedCount)
        lookup.reserveCapacity(expectedCount)
        while !stack.isEmpty {
            try Task.checkCancellation()
            let frame = stack[stack.count - 1]
            if frame.nextLayer < 0 {
                stack.removeLast()
                continue
            }
            stack[stack.count - 1].nextLayer -= 1
            let composition = compositions[frame.compositionIndex]
            let source = composition.layers[frame.nextLayer]
            try budget.reserve(count: frame.path.count + 1, stride: 8)
            var path = frame.path
            path.append(source.id)
            let id = PAGLayerID(document: identity, path: path)
            let index = instances.count
            let instance = LayerInstance(id: id, compositionIndex: frame.compositionIndex, layerIndex: frame.nextLayer,
                                         startTime: try SceneValidator.time(frame: source.startFrame, rate: composition.frameRate),
                                         duration: try SceneValidator.time(frame: source.durationFrames, rate: composition.frameRate),
                                         children: [])
            instances.append(instance)
            lookup[id] = index
            if let parent = frame.parent { instances[parent].children.append(index) }
            else { roots.append(index) }
            if case let .precomposition(sourceID, _) = source.content {
                // 图验证已保证该引用存在；失败也保持明确错误，避免依赖强制解包。
                guard let child = compositionIndices[sourceID] else { throw SceneValidator.invalid("missingCompositionReference") }
                stack.append(ExpansionFrame(compositionIndex: child, nextLayer: compositions[child].layers.count - 1,
                                            parent: index, path: path))
            }
        }
        let duration = try SceneValidator.time(frame: compositions[rootIndex].durationFrames,
                                               rate: compositions[rootIndex].frameRate)
        try Task.checkCancellation()
        return PAGFile(storage: DocumentStorage(identity: identity, compositions: compositions, duration: duration,
                                                instances: instances, rootLayers: roots, layerIndices: lookup,
                                                estimatedBytes: budget.used, resources: resources, catalog: catalog,
                                                topologies: topologies, compositionIndices: compositionIndices,
                                                contentKinds: contentKinds, fileTiming: fileTiming))
    }
}

/// 一层公开遍历的游标；显式栈避免用户提高深度限制后导致调用栈溢出。
private struct ExpansionFrame {
    /// 当前源合成在文档中的下标。
    let compositionIndex: Int
    /// 下一个待读取的源层下标；从末尾递减，负值表示遍历完成。
    var nextLayer: Int
    /// 对应预合成实例的下标；根合成为 nil。
    let parent: Int?
    /// 到当前预合成实例为止的源层 ID 路径。
    let path: [UInt32]
}
