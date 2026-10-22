/// 按源定义DAG分析合成静态帧；只产纯值，不安装缓存或改变实际帧求值。
enum VectorStaticRanges {
    /// 对所有已验证定义做一次后序分析，结果与输入索引一一对应；失败不返回部分表。
    static func make(compositions: [SourceComposition], indices: [UInt32: Int],
                     budget: inout FramePlanBudget) throws -> [StaticFrameRanges] {
        try Task.checkCancellation()
        try budget.reserve(count: compositions.count, stride: 64)
        var states = Array(repeating: UInt8(0), count: compositions.count)
        var results = Array<StaticFrameRanges?>(repeating: nil, count: compositions.count)
        for start in compositions.indices where states[start] == 0 {
            var stack: [(index: Int, exiting: Bool)] = [(start, false)]
            while let current = stack.popLast() {
                try visit(budget: &budget)
                let index = current.index
                if current.exiting {
                    results[index] = try analyze(compositions[index], compositions: compositions,
                                                 indices: indices, results: results, budget: &budget)
                    states[index] = 2
                    continue
                }
                if states[index] == 2 { continue }
                guard states[index] == 0 else { throw SceneValidator.invalid("compositionCycle") }
                states[index] = 1
                try visit(budget: &budget)
                stack.append((index, true))
                // 后入先出；反转入栈使共享子定义按源层顺序先于父定义完成。
                for layer in compositions[index].layers.reversed() {
                    try visit(budget: &budget)
                    guard case let .precomposition(id, _) = layer.content else { continue }
                    guard id > 0, let child = indices[id], compositions.indices.contains(child) else {
                        throw SceneValidator.invalid("missingCompositionReference")
                    }
                    if states[child] == 1 { throw SceneValidator.invalid("compositionCycle") }
                    if states[child] == 0 {
                        try visit(budget: &budget)
                        stack.append((child, false))
                    }
                }
            }
        }
        return try results.map { value in
            guard let value else { throw SceneValidator.invalid("missingStaticComposition") }
            return value
        }
    }

    /// 一份定义先区分媒体与Vector；媒体重叠只关闭分析复用，不修改原始播放帧表。
    private static func analyze(_ composition: SourceComposition, compositions: [SourceComposition],
                                indices: [UInt32: Int],
                                results: [StaticFrameRanges?], budget: inout FramePlanBudget) throws -> StaticFrameRanges {
        try visit(budget: &budget)
        guard composition.durationFrames > 1 else { return try StaticFrameRanges([], budget: &budget) }
        if let bitmap = composition.bitmap {
            return try media(bitmap.staticRanges, budget: &budget)
        }
        if let video = composition.video {
            return try media(video.staticRanges, budget: &budget)
        }
        var current = try StaticFrameRanges(startFrame: 0, duration: composition.durationFrames, budget: &budget)
        for layer in composition.layers {
            try visit(budget: &budget)
            // VectorComposition一旦没有可复用帧便停止后续层；源结构已在SceneValidator验证。
            if current.ranges.isEmpty { break }
            current = try excludingLayer(layer, from: current, in: composition,
                                         compositions: compositions, indices: indices,
                                         results: results, budget: &budget)
            current = try current.splitting(at: layer.startFrame, budget: &budget)
            let end = layer.startFrame.addingReportingOverflow(layer.durationFrames)
            guard !end.overflow else { throw SceneValidator.invalid("staticLayerEndOverflow") }
            current = try current.splitting(at: end.partialValue, budget: &budget)
        }
        return current
    }

    /// 原始媒体区间若不严格有序或相交则保守退空，不能合并出虚假的完整静态段。
    static func media(_ raw: [ClosedRange<Int64>], budget: inout FramePlanBudget) throws -> StaticFrameRanges {
        try Task.checkCancellation()
        var previousEnd: Int64?
        var valid = true
        for range in raw {
            try visit(budget: &budget)
            if let previousEnd, previousEnd >= range.lowerBound { valid = false }
            previousEnd = range.upperBound
        }
        return try StaticFrameRanges(valid ? raw : [], budget: &budget)
    }

    /// 先排二维变换与Layer时间元数据，再按类型排内容，预合成最后交③a安全表。
    private static func excludingLayer(_ layer: SourceLayer, from ranges: StaticFrameRanges,
                                       in composition: SourceComposition, compositions: [SourceComposition],
                                       indices: [UInt32: Int],
                                       results: [StaticFrameRanges?], budget: inout FramePlanBudget) throws -> StaticFrameRanges {
        var current = ranges
        current = try excluding(layer.transform.anchor, from: current, budget: &budget)
        switch layer.transform.position {
        case .combined(let position):
            current = try excluding(position, from: current, budget: &budget)
        case .separated(let x, let y):
            current = try excluding(x, from: current, budget: &budget)
            current = try excluding(y, from: current, budget: &budget)
        }
        current = try excluding(layer.transform.scale, from: current, budget: &budget)
        current = try excluding(layer.transform.rotation, from: current, budget: &budget)
        current = try excluding(layer.transform.opacity, from: current, budget: &budget)
        current = try excluding(layer.timing.timeRemap, from: current, budget: &budget)
        // Layer::excludeVaryingRanges逐条排除原始蒙版轨道；None也不能被当前帧的可见性优化掉。
        for mask in layer.masks {
            try visit(budget: &budget)
            current = try excluding(mask.path, from: current, budget: &budget)
            if let feather = mask.feather {
                current = try excluding(feather, from: current, budget: &budget)
            }
            current = try excluding(mask.opacity, from: current, budget: &budget)
            current = try excluding(mask.expansion, from: current, budget: &budget)
        }
        if !layer.textAnimators.isEmpty {
            // 文字动画器的当帧字形内容不能由定义级Vector快照跨帧复用。
            return try StaticFrameRanges([], budget: &budget)
        }
        switch layer.content {
        case .shape(let elements):
            // ShapeLayer的内容排除发生在Layer自身轨道之后，必须保留父合成时间坐标。
            current = try ShapeContentRanges.excluding(elements, from: current, budget: &budget)
        case .precomposition(let id, let start):
            guard id > 0, let index = indices[id], results.indices.contains(index),
                  let childRanges = results[index] else { throw SceneValidator.invalid("missingCompositionReference") }
            let child = compositions[index]
            current = try PrecompositionStaticRanges.intersectingContent(current, child: childRanges,
                childDuration: child.durationFrames, parentRate: composition.frameRate,
                childRate: child.frameRate, compositionStart: start, layerStart: layer.startFrame,
                layerDuration: layer.durationFrames, budget: &budget)
        case .null, .solid, .text, .image:
            // 无动画器的TextSource是静态；ImageFillRule不属于Layer的静态排除轨道。
            break
        }
        return current
    }

    /// 每条外层轨道即使常量也计访问成本，关键帧排除交给区间内核。
    private static func excluding<Value>(_ property: SourceProperty<Value>, from ranges: StaticFrameRanges,
                                         budget: inout FramePlanBudget) throws -> StaticFrameRanges {
        try visit(budget: &budget)
        return try ranges.excluding(property, budget: &budget)
    }

    /// 每次定义、图边、图层及轨道访问前检查取消并收费。
    private static func visit(budget: inout FramePlanBudget) throws {
        try Task.checkCancellation()
        try budget.reserve(stride: 32)
    }
}
