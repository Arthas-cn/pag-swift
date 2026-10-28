/// 一次合成帧求值的局部矩阵缓存；只采样请求层及其控制祖先，不跨任务共享可变状态。
struct LayerTransformSampler {
    /// 当前已验证的源合成；所有属性帧均以此合成时间轴表达。
    private let source: SourceComposition
    /// 与 source 完全对应且无环的父链索引。
    private let topology: CompositionTopology
    /// 本次采样固定的所属合成帧号，不随各层 startFrame 改变。
    private let frame: Int64
    /// 已计算的累计父矩阵；nil 表示该层尚未被请求，opacity 始终为该层自身值。
    private var cached: [EvaluatedTransform?]

    /// 从已验证的源合成和匹配索引建立一次采样；调用方不能混用其他合成的 topology。
    init(source: SourceComposition, topology: CompositionTopology, frame: Int64) {
        self.source = source
        self.topology = topology
        self.frame = frame
        cached = Array(repeating: nil, count: source.layers.count)
    }

    /// 返回源下标对应的累计父矩阵及自身 opacity；取消、属性或矩阵溢出继续向外抛出。
    mutating func transform(for index: Int) throws -> EvaluatedTransform {
        try Task.checkCancellation()
        guard source.layers.indices.contains(index) else { throw PAGError.invalidArgument("layerIndex") }
        if let value = cached[index] { return value }
        var path: [Int] = []
        var next: Int? = index
        while let current = next, cached[current] == nil {
            try Task.checkCancellation()
            path.append(current)
            next = topology.parents[current]
        }
        // 无环性在载入时已验证。反向处理路径，保证父累计矩阵先就绪，且不递归消耗调用栈。
        for current in path.reversed() {
            try Task.checkCancellation()
            var value = try TransformEvaluation.layer(source.layers[current].transform.value(at: frame))
            if let parent = topology.parents[current], let parentValue = cached[parent] {
                // 控制父层的 active、可见区间和 opacity 不传给孩子；这里只追加同帧矩阵。
                value = try value.followingParent(parentValue)
            }
            cached[current] = value
        }
        guard let result = cached[index] else { throw SceneValidator.invalid("missingEvaluatedTransform") }
        return result
    }
}
