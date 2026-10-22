/// 预合成内容在父合成帧中的安全静态范围；只分析时间，不创建Picture或改变播放采样。
enum PrecompositionStaticRanges {
    /// 从已排除外层轨道的父范围求交子内容范围；帧率、边界、预算或取消失败均不返回部分结果。
    static func intersectingContent(_ parent: StaticFrameRanges, child: StaticFrameRanges,
                                    childDuration: Int64, parentRate: Double, childRate: Double,
                                    compositionStart: Int64, layerStart: Int64, layerDuration: Int64,
                                    budget: inout FramePlanBudget) throws -> StaticFrameRanges {
        try Task.checkCancellation()
        // Layer自身排除后若已无静态帧，源码不再访问子合成；保留这一短路且仍响应取消。
        if parent.ranges.isEmpty { return parent }
        guard childDuration > 0, parentRate.isFinite, childRate.isFinite,
              parentRate > 0, childRate > 0 else { throw SceneValidator.invalid("precompositionStaticTimeScale") }
        let forward = Float(parentRate) / Float(childRate)
        let reverse = Float(childRate) / Float(parentRate)
        guard forward.isFinite, forward > 0, reverse.isFinite, reverse > 0 else {
            throw SceneValidator.invalid("precompositionStaticTimeScale")
        }
        let visible = try StaticFrameRanges(startFrame: layerStart, duration: layerDuration, budget: &budget)
        guard let last = visible.ranges.first?.upperBound else { throw SceneValidator.invalid("precompositionVisibleRange") }
        var allowed: [ClosedRange<Int64>] = []

        // 源对层外头部也要求至少两帧；只把真正可复用的段交给父范围求交。
        if layerStart > 1 { try append(0...(layerStart - 1), to: &allowed, budget: &budget) }
        for source in child.ranges {
            try visit(budget: &budget)
            // Bitmap/Video的源静态端点可能越过标称duration；按实际钳制采样收窄，不能据此拒文件。
            let first = try mapped(source.lowerBound, scale: forward, offset: compositionStart)
            let end = try mapped(source.upperBound, scale: forward, offset: compositionStart)
            // 保留PreComposeLayer的严格边界：触到可见首末点的候选不产生内容静态段。
            guard end > layerStart, first < last else { continue }
            let clipped = max(first, layerStart)...min(end, last)
            guard clipped.lowerBound < clipped.upperBound else { continue }
            for current in parent.ranges {
                try visit(budget: &budget)
                let lower = max(clipped.lowerBound, current.lowerBound)
                let upper = min(clipped.upperBound, current.upperBound)
                guard lower < upper else { continue }
                let domain = lower...upper
                if let safe = try safeInterval(domain, child: source, childLast: childDuration - 1,
                                               reverse: reverse, compositionStart: compositionStart,
                                               budget: &budget), safe.lowerBound < safe.upperBound {
                    try append(safe, to: &allowed, budget: &budget)
                }
            }
        }
        if last < .max, let parentLast = parent.ranges.last?.upperBound,
           last + 1 < parentLast {
            try append((last + 1)...parentLast, to: &allowed, budget: &budget)
        }
        let candidate = try StaticFrameRanges(allowed, budget: &budget)
        return try parent.intersection(candidate, budget: &budget)
    }

    /// 按源码Float32乘法及roundf映射一个子端点，再检查父帧偏移溢出。
    private static func mapped(_ frame: Int64, scale: Float, offset: Int64) throws -> Int64 {
        let rounded = (Float(frame) * scale).rounded(.toNearestOrAwayFromZero)
        guard rounded.isFinite, let value = Int64(exactly: rounded) else {
            throw SceneValidator.invalid("precompositionStaticRangeOverflow")
        }
        let result = value.addingReportingOverflow(offset)
        guard !result.overflow else { throw SceneValidator.invalid("precompositionStaticRangeOverflow") }
        return result.partialValue
    }

    /// 实际消费先用反向Float32时间比采样，再由子合成缓存钳到合法帧。
    private static func sampledChildFrame(_ parentFrame: Int64, compositionStart: Int64,
                                          scale: Float, childLast: Int64) throws -> Int64 {
        let difference = parentFrame.subtractingReportingOverflow(compositionStart)
        guard !difference.overflow else { throw SceneValidator.invalid("precompositionStaticRangeOverflow") }
        let rounded = (Float(difference.partialValue) * scale).rounded(.toNearestOrAwayFromZero)
        guard rounded.isFinite, let frame = Int64(exactly: rounded) else {
            throw SceneValidator.invalid("precompositionStaticRangeOverflow")
        }
        return min(max(frame, 0), childLast)
    }

    /// 在当前父静态段内求反向采样落入同一子静态段的连续逆像，不逐帧遍历大时长。
    private static func safeInterval(_ domain: ClosedRange<Int64>, child: ClosedRange<Int64>,
                                     childLast: Int64, reverse: Float, compositionStart: Int64,
                                     budget: inout FramePlanBudget) throws -> ClosedRange<Int64>? {
        let first = try firstFrame(in: domain, budget: &budget) { frame in
            try sampledChildFrame(frame, compositionStart: compositionStart, scale: reverse,
                                  childLast: childLast) >= child.lowerBound
        }
        guard let first else { return nil }
        let last = try lastFrame(in: first...domain.upperBound, budget: &budget) { frame in
            try sampledChildFrame(frame, compositionStart: compositionStart, scale: reverse,
                                  childLast: childLast) <= child.upperBound
        }
        guard let last, first <= last else { return nil }
        return first...last
    }

    /// 用带符号偏置的UInt64二分找首个命中帧，避免跨Int64零点的中点溢出。
    private static func firstFrame(in domain: ClosedRange<Int64>, budget: inout FramePlanBudget,
                                   matching predicate: (Int64) throws -> Bool) throws -> Int64? {
        var low = biased(domain.lowerBound)
        var high = biased(domain.upperBound)
        var found: UInt64?
        while low <= high {
            try visit(budget: &budget)
            let middle = low + (high - low) / 2
            if try predicate(unbiased(middle)) {
                found = middle
                if middle == 0 { break }
                high = middle - 1
            } else {
                if middle == .max { break }
                low = middle + 1
            }
        }
        return found.map(unbiased)
    }

    /// 用同一无溢出二分找最后命中帧；谓词由单调反向采样保证先真后假。
    private static func lastFrame(in domain: ClosedRange<Int64>, budget: inout FramePlanBudget,
                                  matching predicate: (Int64) throws -> Bool) throws -> Int64? {
        var low = biased(domain.lowerBound)
        var high = biased(domain.upperBound)
        var found: UInt64?
        while low <= high {
            try visit(budget: &budget)
            let middle = low + (high - low) / 2
            if try predicate(unbiased(middle)) {
                found = middle
                if middle == .max { break }
                low = middle + 1
            } else {
                if middle == 0 { break }
                high = middle - 1
            }
        }
        return found.map(unbiased)
    }

    /// 把有符号顺序映到无符号顺序，供极端帧号的二分使用。
    private static func biased(_ value: Int64) -> UInt64 { UInt64(bitPattern: value) ^ 0x8000_0000_0000_0000 }

    /// 将二分索引还原为源帧号，不经浮点往返。
    private static func unbiased(_ value: UInt64) -> Int64 { Int64(bitPattern: value ^ 0x8000_0000_0000_0000) }

    /// 在追加候选前先为暂存区间付费，避免只计最终求交结果。
    private static func append(_ range: ClosedRange<Int64>, to output: inout [ClosedRange<Int64>],
                               budget: inout FramePlanBudget) throws {
        try visit(budget: &budget)
        output.append(range)
    }

    /// 每个子段、父段和二分采样先检查取消并预付逻辑工作量。
    private static func visit(budget: inout FramePlanBudget) throws {
        try Task.checkCancellation()
        try budget.reserve(stride: 32)
    }
}
