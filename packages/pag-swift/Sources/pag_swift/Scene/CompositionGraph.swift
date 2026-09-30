/// 合成引用图的迭代后序验证；包括不可达源合成，不先展开实例。
enum CompositionGraph {
    /// 返回每个合成展开后的节点数；环、缺失引用、深度或数量超限立即失败。
    static func validate(_ compositions: [SourceComposition], indices: [UInt32: Int],
                         limits: PAGLoadLimits) throws -> [Int] {
        var edges = Array(repeating: [Int](), count: compositions.count)
        for (index, composition) in compositions.enumerated() {
            for layer in composition.layers {
                try Task.checkCancellation()
                if case let .precomposition(id, _) = layer.content {
                    // ReadCompositionReference将0解释为无引用，不能绑定到合法的ID0合成定义。
                    guard id > 0, let child = indices[id] else { throw SceneValidator.invalid("missingCompositionReference") }
                    edges[index].append(child)
                }
            }
        }
        var states = Array(repeating: UInt8(0), count: compositions.count)
        var counts = Array(repeating: 0, count: compositions.count)
        var depths = Array(repeating: 0, count: compositions.count)
        for start in compositions.indices where states[start] == 0 {
            var stack: [(index: Int, exiting: Bool)] = [(start, false)]
            while let visit = stack.popLast() {
                try Task.checkCancellation()
                let index = visit.index
                if visit.exiting {
                    var count = compositions[index].layers.count
                    var depth = 1
                    for child in edges[index] {
                        // 一条引用计一次子实例数；共享源合成不能让展开预算少算。
                        guard counts[child] <= limits.maximumLayerCount - count else {
                            throw PAGError.resourceLimitExceeded("maximumLayerCount")
                        }
                        count += counts[child]
                        guard depths[child] < limits.maximumCompositionDepth else {
                            throw PAGError.resourceLimitExceeded("maximumCompositionDepth")
                        }
                        depth = max(depth, depths[child] + 1)
                    }
                    counts[index] = count
                    depths[index] = depth
                    states[index] = 2
                } else {
                    if states[index] == 2 { continue }
                    guard states[index] == 0 else { throw SceneValidator.invalid("compositionCycle") }
                    states[index] = 1
                    stack.append((index, true))
                    for child in edges[index].reversed() { stack.append((child, false)) }
                }
            }
        }
        return counts
    }
}
