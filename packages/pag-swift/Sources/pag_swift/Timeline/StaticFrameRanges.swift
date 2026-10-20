/// 上游TimeRange的不可变闭区间集合；只处理时间，不判断图层内容或选择GPU快照。
struct StaticFrameRanges: Sendable, Equatable {
    /// 按起点递增且互不重叠；允许单帧和相邻片段，相邻Hold不能合并。
    let ranges: [ClosedRange<Int64>]

    /// 校验已有闭区间并计入留存预算；乱序或重叠抛invalidFile，不修改调用方数组。
    init(_ ranges: [ClosedRange<Int64>], budget: inout FramePlanBudget) throws {
        try Task.checkCancellation()
        var previousEnd: Int64?
        for range in ranges {
            try Self.visit(budget: &budget)
            if let previousEnd, previousEnd >= range.lowerBound {
                throw SceneValidator.invalid("invalidStaticFrameRanges")
            }
            previousEnd = range.upperBound
        }
        try budget.reserve(count: ranges.count, stride: 32)
        self.ranges = ranges
    }

    /// 从正时长建立唯一完整区间；非正时长或终点溢出抛invalidFile。
    init(startFrame: Int64, duration: Int64, budget: inout FramePlanBudget) throws {
        try Self.visit(budget: &budget)
        let end = try Self.endFrame(start: startFrame, duration: duration)
        try budget.reserve(stride: 32)
        ranges = [startFrame...end]
    }

    /// 接收本类型算法已校验且已付费的输出，避免再次扫描或重复收费。
    private init(validated ranges: [ClosedRange<Int64>]) {
        self.ranges = ranges
    }

    /// 在指定帧处分割；新生单帧丢弃，未被分割的原单帧保留，预算或取消时不返回部分值。
    func splitting(at frame: Int64, budget: inout FramePlanBudget) throws -> Self {
        try Task.checkCancellation()
        var output: [ClosedRange<Int64>] = []
        for range in ranges {
            try Self.visit(budget: &budget)
            guard range.lowerBound < frame, frame <= range.upperBound else {
                try Self.append(range, to: &output, budget: &budget)
                continue
            }
            // frame大于一个可表示起点，减1不会下溢；源Split丢弃切出的单帧。
            if range.lowerBound < frame - 1 {
                try Self.append(range.lowerBound...(frame - 1), to: &output, budget: &budget)
            }
            if frame < range.upperBound {
                try Self.append(frame...range.upperBound, to: &output, budget: &budget)
            }
        }
        return Self(validated: output)
    }

    /// 扣除闭区间；逆序区间按源规则转为起点分割，失败保持原集合不变。
    func subtracting(from start: Int64, through end: Int64, budget: inout FramePlanBudget) throws -> Self {
        try Task.checkCancellation()
        if end < start { return try splitting(at: start, budget: &budget) }
        var output: [ClosedRange<Int64>] = []
        for range in ranges {
            try Self.visit(budget: &budget)
            guard range.upperBound >= start, range.lowerBound <= end else {
                try Self.append(range, to: &output, budget: &budget)
                continue
            }
            // 只有存在左/右余量时才做±1，避免Int64极端输入的中间溢出。
            if range.lowerBound < start, range.lowerBound < start - 1 {
                try Self.append(range.lowerBound...(start - 1), to: &output, budget: &budget)
            }
            if end < range.upperBound, end + 1 < range.upperBound {
                try Self.append((end + 1)...range.upperBound, to: &output, budget: &budget)
            }
        }
        return Self(validated: output)
    }

    /// 求两组静态区间的交集；保留单帧交点和相邻片段，不执行规范化合并。
    func intersection(_ other: Self, budget: inout FramePlanBudget) throws -> Self {
        try Task.checkCancellation()
        var output: [ClosedRange<Int64>] = []
        var left = 0
        var right = 0
        while left < ranges.count, right < other.ranges.count {
            try Self.visit(budget: &budget)
            let a = ranges[left]
            let b = other.ranges[right]
            let start = max(a.lowerBound, b.lowerBound)
            let end = min(a.upperBound, b.upperBound)
            if start <= end { try Self.append(start...end, to: &output, budget: &budget) }
            // 至少推进一个已耗尽区间，扫描次数受两组输入总量约束。
            if a.upperBound <= b.upperBound { left += 1 }
            if b.upperBound <= a.upperBound { right += 1 }
        }
        return Self(validated: output)
    }

    /// 平移全部端点；任一端点溢出抛invalidFile，不发布已完成的前缀。
    func offsetting(by offset: Int64, budget: inout FramePlanBudget) throws -> Self {
        try Task.checkCancellation()
        var output: [ClosedRange<Int64>] = []
        for range in ranges {
            try Self.visit(budget: &budget)
            let start = range.lowerBound.addingReportingOverflow(offset)
            let end = range.upperBound.addingReportingOverflow(offset)
            guard !start.overflow, !end.overflow else { throw SceneValidator.invalid("staticFrameRangeOverflow") }
            try Self.append(start.partialValue...end.partialValue, to: &output, budget: &budget)
        }
        return Self(validated: output)
    }

    /// 转为相对指定原点的帧坐标；直接检查减法，允许原点为Int64.min但结果可表示。
    func relative(to origin: Int64, budget: inout FramePlanBudget) throws -> Self {
        try Task.checkCancellation()
        var output: [ClosedRange<Int64>] = []
        for range in ranges {
            try Self.visit(budget: &budget)
            // 不能先计算-origin；最小负数无法取反，但局部帧差仍可能完全合法。
            let start = range.lowerBound.subtractingReportingOverflow(origin)
            let end = range.upperBound.subtractingReportingOverflow(origin)
            guard !start.overflow, !end.overflow else { throw SceneValidator.invalid("staticFrameRangeOverflow") }
            try Self.append(start.partialValue...end.partialValue, to: &output, budget: &budget)
        }
        return Self(validated: output)
    }

    /// 排除属性变化；仅消费时间与easing，同值动画仍有变化，常量保持原集合。
    func excluding<Value>(_ property: SourceProperty<Value>, budget: inout FramePlanBudget) throws -> Self {
        try Task.checkCancellation()
        var result = self
        for keyframe in property.keyframes {
            try Self.visit(budget: &budget)
            switch keyframe.easing {
            case .none, .hold:
                // None数值虽按Linear插值，上游静态范围仍走default分割，不能只按数值行为合并。
                result = try result.splitting(at: keyframe.startFrame, budget: &budget)
                result = try result.splitting(at: keyframe.endFrame, budget: &budget)
            case .linear, .bezier:
                // 零跨度包括Int64.min：源Subtract会退回Split，不先计算不可表示的end−1。
                if keyframe.startFrame == keyframe.endFrame {
                    result = try result.splitting(at: keyframe.startFrame, budget: &budget)
                } else {
                    result = try result.subtracting(from: keyframe.startFrame, through: keyframe.endFrame - 1,
                                                    budget: &budget)
                }
            }
        }
        return result
    }

    /// 仅唯一完整区间算静态；相邻片段即使覆盖同一帧集合也不能当作完整静态。
    func covers(startFrame: Int64, duration: Int64) throws -> Bool {
        try Task.checkCancellation()
        let end = try Self.endFrame(start: startFrame, duration: duration)
        return ranges.count == 1 && ranges[0] == startFrame...end
    }

    /// 二分查找命中区间的起点；未命中原样返回，不保存跨调用游标。
    func representativeFrame(for frame: Int64, budget: inout FramePlanBudget) throws -> Int64 {
        try Task.checkCancellation()
        var low = 0
        var high = ranges.count
        while low < high {
            try Self.visit(budget: &budget)
            let middle = low + (high - low) / 2
            let range = ranges[middle]
            if frame < range.lowerBound { high = middle }
            else if frame > range.upperBound { low = middle + 1 }
            else { return range.lowerBound }
        }
        return frame
    }

    /// 计算闭区间终点，先减时长再相加，避免合法Int64.max末帧被中间溢出误拒绝。
    private static func endFrame(start: Int64, duration: Int64) throws -> Int64 {
        guard duration > 0 else { throw SceneValidator.invalid("invalidStaticFrameDuration") }
        let end = start.addingReportingOverflow(duration - 1)
        guard !end.overflow else { throw SceneValidator.invalid("staticFrameRangeOverflow") }
        return end.partialValue
    }

    /// 每次扫描先检查取消并预付工作量；预算累计不因临时输出被替换而退还。
    private static func visit(budget: inout FramePlanBudget) throws {
        try Task.checkCancellation()
        try budget.reserve(stride: 32)
    }

    /// 输出前预付逻辑保活成本；不提前reserveCapacity，避免在计费前分配整张表。
    private static func append(_ range: ClosedRange<Int64>, to output: inout [ClosedRange<Int64>],
                               budget: inout FramePlanBudget) throws {
        try Task.checkCancellation()
        try budget.reserve(stride: 32)
        output.append(range)
    }
}
