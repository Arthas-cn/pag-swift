/// 羽化蒙版中实际绘制的一项；透明度与模糊值在所属合成帧求值，后续模式不参与布尔运算。
struct SampledFeatherMaskDraw: Sendable {
    /// 首个可绘项遇Subtract时已翻转的补集位；退化bounds仍会消耗这个首项身份。
    let isInverted: Bool
    /// 该项路径写入自己的alpha表面时采用的0...255源透明度。
    let opacity: UInt8
    /// 原始羽化宽高；nil表示没有滤镜，零或负轴由渲染层按上游滤镜规则处理。
    let feather: ScenePoint?
}

/// 羽化分支的单个测量项；None和开放路径仍参与总体bounds测量，但不生成alpha图。
struct SampledFeatherMaskItem: Sendable {
    /// 原始蒙版身份；即使不同项共享同一路径，顺序与来源仍须保留。
    let sourceID: UInt32
    /// 在父合成帧采样的源路径，供扩张和总体bounds测量使用。
    let path: SourcePath
    /// 该帧Float扩张值；每一项先扩张，再测量或绘制。
    let expansion: Float
    /// 有效末Close且模式非None才非nil；仅Close也能消耗首项身份。
    let draw: SampledFeatherMaskDraw?
}

/// 一层羽化或蒙版透明度的完整有序采样结果；尚不决定局部表面尺寸或发布GPU输入。
struct SampledFeatherMask: Sendable {
    /// 源列表中的每一项，包括不会绘制、但会改变总体测量结果的项。
    let items: [SampledFeatherMaskItem]
}

/// 在进入GPU之前按上游羽化分支保留完整源顺序与首Subtract语义。
enum FeatherMaskSampling {
    /// 普通路径层返回nil；羽化分支完整采样后返回纯值，取消、坏值或超预算不发布部分结果。
    static func sample(_ masks: [SourceMask], at frame: Int64,
                       budget: inout FramePlanBudget) throws -> SampledFeatherMask? {
        try Task.checkCancellation()
        var usesFeather = false
        for mask in masks {
            try Task.checkCancellation()
            try budget.reserve(stride: 32)
            // LayerCache先扫描完整列表，None和开放路径仍可令整层改走羽化分支。
            if mask.feather != nil || mask.opacity.isAnimated || mask.opacity.initialValue != 255 {
                usesFeather = true
            }
        }
        guard usesFeather else { return nil }

        var items: [SampledFeatherMaskItem] = []
        var isFirst = true
        for mask in masks {
            try Task.checkCancellation()
            try budget.reserve(stride: 48)
            let path = try PropertyEvaluation.path(mask.path, at: frame, budget: &budget)
            try budget.reserve(stride: path.estimatedBytes)
            let expansion = Float(try PropertyEvaluation.scalar(mask.expansion, at: frame))
            guard expansion.isFinite else { throw SceneValidator.invalid("unrepresentablePropertyValue") }
            // FeatherMask的总体bounds循环先扩张所有路径，不能跳过未绘制项的非法宽度。
            guard (abs(expansion) * 2).isFinite else {
                throw PAGError.resourceLimitExceeded("maximumStrokeMagnitude")
            }

            var draw: SampledFeatherMaskDraw?
            if path.verbs.last == .close, mask.mode != .none {
                let inverted = mask.isInverted != (isFirst && mask.mode == .subtract)
                isFirst = false
                let opacity = try PropertyEvaluation.opacity(mask.opacity, at: frame)
                let feather = try mask.feather.map { try PropertyEvaluation.point($0, at: frame) }
                if let feather {
                    guard Float(feather.x).isFinite, Float(feather.y).isFinite else {
                        throw SceneValidator.invalid("unrepresentablePropertyValue")
                    }
                }
                try budget.reserve(stride: 32)
                draw = SampledFeatherMaskDraw(isInverted: inverted, opacity: opacity, feather: feather)
            }
            items.append(SampledFeatherMaskItem(sourceID: mask.id, path: path,
                                                expansion: expansion == 0 ? 0 : expansion, draw: draw))
        }
        try Task.checkCancellation()
        return SampledFeatherMask(items: items)
    }
}
