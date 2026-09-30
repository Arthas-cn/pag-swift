/// 已变换到根帧轴的素材段；闭区间取整可造成重叠或空段，不要求SourceProperty的连续拓扑。
struct ImageTimeSegment: Sendable {
    /// 根帧轴起点，可以在文件可见区间之外。
    let start: Int64
    /// 根帧轴终点；缩小后的空段允许终点比起点早一帧。
    let end: Int64
    /// Float来源的素材起帧值，保留上游复制和缩放的精度。
    let first: Float
    /// 素材终帧值，可小于first形成倒向播放。
    let last: Float
    /// 初始化后不可变的缓动；裁剪不重新生成Bezier曲线。
    let easing: SourceEasing

    /// 源码CreateKeyframe的时间参数也是float；仅生成的默认/补段经此路径，原始动画段不量化。
    static func generated(start: Int64, end: Int64, first: Float, last: Float) throws -> ImageTimeSegment {
        guard let a = Int64(exactly: Float(start)), let b = Int64(exactly: Float(end)) else {
            throw SceneValidator.invalid("unrepresentableImageTime")
        }
        return ImageTimeSegment(start: a, end: b, first: first, last: last, easing: .linear)
    }

    /// 取得端值或插值；裁剪时关闭端点钳制以保持Hold基类在终点仍返回起值的源码行为。
    func value(at frame: Int64, clamped: Bool = true) throws -> Float {
        if clamped {
            // 起点优先使零段/空段只选端值，不进入后面的区间除法。
            if frame <= start { return first }
            if frame >= end { return last }
        }
        if case .hold = easing { return first }
        let length = try ImageTimeMath.subtract(end, start)
        guard length > 0 else { throw SceneValidator.invalid("emptyImageTimeInterpolation") }
        let progress = Float(try ImageTimeMath.subtract(frame, start)) / Float(length)
        let eased: Float
        switch easing {
        case .linear: eased = progress
        case .bezier(let curve, _): eased = curve.timing(at: progress)
        case .hold: eased = 0
        }
        let result = first + (last - first) * eased
        guard result.isFinite else { throw SceneValidator.invalid("unrepresentableImageTime") }
        return result
    }

    /// 按CutKeyframe计算切点端值；保留原interpolator，不重建被源码修改但未重新初始化的控制点。
    func cut(at frame: Int64, left: Bool) throws -> ImageTimeSegment {
        let value = try value(at: frame, clamped: false)
        return ImageTimeSegment(start: left ? frame : start, end: left ? end : frame,
                                first: left ? value : first, last: left ? last : value, easing: easing)
    }
}

/// 单个图片实例的不可变素材时间映射；不推进根时钟，也不授予图层显示资格。
struct ImageTimeMapping: Sendable {
    /// 图层闭区间沿真实预合成祖先映射到根的起点，不预先裁到文件范围。
    let visibleStart: Int64
    /// 同一根闭区间终点，大于等于visibleStart。
    let visibleEnd: Int64
    /// 按编码顺序的已缩放段；空数组代表源码单帧/完全不可见分支的常量零。
    let segments: [ImageTimeSegment]
    /// 段终点的累计最大值；生成补段的Float量化可能打破原始终点排序，二分不能直接用原数组。
    private let endBounds: [Int64]

    /// 按PAGImageLayer的原始文件时长路径准备轨道；取消、预算或不可表示算术均丢弃整个结果。
    static func make(layer: SourceLayer, visibleStart: Int64, visibleEnd: Int64,
                     fileDuration: Int64, budget: inout FramePlanBudget) throws -> ImageTimeMapping {
        try Task.checkCancellation()
        guard layer.durationFrames > 0, fileDuration > 0, visibleEnd >= visibleStart else {
            throw SceneValidator.invalid("invalidImageTimeRange")
        }
        try budget.reserve(stride: 128)
        let fileEnd = fileDuration - 1
        if visibleStart == visibleEnd || visibleEnd < 0 || visibleStart > fileEnd {
            // 源码把单一根帧或文件外映射设为常量0；这不代替实际显示资格和区间外采样规则。
            return ImageTimeMapping(visibleStart: visibleStart, visibleEnd: visibleEnd, segments: [], endBounds: [])
        }
        let length = try ImageTimeMath.add(ImageTimeMath.subtract(visibleEnd, visibleStart), 1)
        let scale = Double(length) / Double(layer.durationFrames)
        let property = layer.imageFillRule?.timeRemap
        let count = max(property?.keyframes.count ?? 0, 1)
        try budget.reserve(count: count, stride: 320)
        var segments: [ImageTimeSegment] = []
        if let property, property.isAnimated {
            for key in property.keyframes {
                try Task.checkCancellation()
                let start = try ImageTimeMath.subtract(key.startFrame, layer.startFrame)
                let end = try ImageTimeMath.subtract(key.endFrame, layer.startFrame)
                let segment = ImageTimeSegment(start: start, end: end, first: Float(key.startValue),
                                               last: Float(key.endValue), easing: key.easing)
                if let mapped = try scaled(segment, origin: visibleStart, scale: scale, fileEnd: fileEnd) {
                    segments.append(mapped)
                }
            }
        } else {
            // 缺失和常量规则都使用默认线性区间；常量0不能把替换素材冻结在首帧。
            let end = try ImageTimeMath.add(layer.startFrame, layer.durationFrames - 1)
            let generated = try ImageTimeSegment.generated(start: layer.startFrame, end: end,
                                                             first: Float(layer.startFrame), last: Float(end))
            let segment = try ImageTimeSegment(start: ImageTimeMath.subtract(generated.start, layer.startFrame),
                end: ImageTimeMath.subtract(generated.end, layer.startFrame), first: generated.first,
                last: generated.last, easing: generated.easing)
            if let mapped = try scaled(segment, origin: visibleStart, scale: scale, fileEnd: fileEnd) {
                segments.append(mapped)
            }
        }
        if segments.isEmpty {
            // 源动画全部在文件之外时，源码补原可见区间的线性段，不再对补段执行第二轮裁剪。
            segments.append(try ImageTimeSegment.generated(start: visibleStart, end: visibleEnd,
                                                             first: 0, last: Float(length - 1)))
        } else {
            var minimum = Float.greatestFiniteMagnitude
            for segment in segments {
                try Task.checkCancellation()
                minimum = min(minimum, segment.first).rounded(.toNearestOrAwayFromZero)
                minimum = min(minimum, segment.last).rounded(.toNearestOrAwayFromZero)
            }
            segments = try segments.map { segment in
                try Task.checkCancellation()
                return ImageTimeSegment(start: segment.start, end: segment.end,
                    first: segment.first - minimum, last: segment.last - minimum, easing: segment.easing)
            }
        }
        if let first = segments.first, first.start > 0 {
            try budget.reserve(stride: 192)
            segments.insert(try ImageTimeSegment.generated(start: 0, end: first.start,
                                                            first: first.first, last: first.first), at: 0)
        }
        if let last = segments.last, last.end < fileEnd {
            try budget.reserve(stride: 192)
            segments.append(try ImageTimeSegment.generated(start: last.end, end: fileEnd,
                                                             first: last.last, last: last.last))
        }
        try budget.reserve(count: segments.count, stride: 16)
        var endBounds: [Int64] = []
        var maximum = Int64.min
        for segment in segments {
            try Task.checkCancellation()
            maximum = max(maximum, segment.end)
            endBounds.append(maximum)
        }
        try Task.checkCancellation()
        return ImageTimeMapping(visibleStart: visibleStart, visibleEnd: visibleEnd, segments: segments, endBounds: endBounds)
    }

    /// 二分取得确定性素材帧并ceil成微秒；可见区间之外按源码使用根帧时间，允许Bezier产生负素材时间。
    func time(at frame: Int64, frameRate: Double) throws -> PAGTime {
        guard frameRate.isFinite, frameRate > 0 else { throw SceneValidator.invalid("unrepresentableImageTime") }
        if frame < visibleStart || frame > visibleEnd { return try SceneValidator.time(frame: frame, rate: frameRate) }
        guard !segments.isEmpty else { return .zero }
        var low = 0
        var high = segments.count - 1
        while low < high {
            let middle = low + (high - low) / 2
            // 重叠/空隙固定按终点选段，消除上游共享lastKeyframeIndex带来的访问顺序差异。
            if frame >= endBounds[middle] { low = middle + 1 }
            else { high = middle }
        }
        let value = try segments[low].value(at: frame)
        let microseconds = (Double(value) * 1_000_000 / frameRate).rounded(.up)
        guard let result = Int64(exactly: microseconds) else {
            throw SceneValidator.invalid("unrepresentableImageTime")
        }
        return PAGTime(microseconds: result)
    }

    /// 缩放源段再按根文件范围去除/裁剪；返回nil表示整段位于文件外，并非读取失败。
    private static func scaled(_ segment: ImageTimeSegment, origin: Int64, scale: Double,
                               fileEnd: Int64) throws -> ImageTimeSegment? {
        let start = try ImageTimeMath.add(origin, ImageTimeMath.roundedFrame(Double(segment.start) * scale))
        // 时间是整数，原式更新start后再算duration会精确抵消；保留闭区间+1/-1而不重复加偏移。
        let end = try ImageTimeMath.subtract(ImageTimeMath.add(origin,
            ImageTimeMath.roundedFrame(Double(ImageTimeMath.add(segment.end, 1)) * scale)), 1)
        let first = Float(try ImageTimeMath.roundedFrame(Double(segment.first) * scale))
        // 值是Float：这里保留源码先改startValue再计算长度的运算顺序，不能直接用Double(end+1)。
        let valueLength = segment.last - first + 1
        let last = Float(try ImageTimeMath.subtract(ImageTimeMath.roundedFrame(Double(first + valueLength) * scale), 1))
        if start > fileEnd || end < 0 { return nil }
        var result = ImageTimeSegment(start: start, end: end, first: first, last: last, easing: segment.easing)
        if end > fileEnd { result = try result.cut(at: fileEnd, left: false) }
        if start < 0 { result = try result.cut(at: 0, left: true) }
        return result
    }
}

/// 素材帧变换的有界算术；所有不确定的整数转换都保持文件错误语义。
enum ImageTimeMath {
    /// 相加溢出时失败，不让祖先偏移或闭区间端点回绕。
    static func add(_ a: Int64, _ b: Int64) throws -> Int64 {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow else { throw SceneValidator.invalid("unrepresentableImageTime") }
        return result.partialValue
    }

    /// 相减溢出时失败，覆盖源起点移除和区间跨度。
    static func subtract(_ a: Int64, _ b: Int64) throws -> Int64 {
        let result = a.subtractingReportingOverflow(b)
        guard !result.overflow else { throw SceneValidator.invalid("unrepresentableImageTime") }
        return result.partialValue
    }

    /// 按源码round半值远离零，结果须能精确放入Int64；不截断无限或越界值。
    static func roundedFrame(_ value: Double) throws -> Int64 {
        guard let result = Int64(exactly: value.rounded(.toNearestOrAwayFromZero)) else {
            throw SceneValidator.invalid("unrepresentableImageTime")
        }
        return result
    }
}
