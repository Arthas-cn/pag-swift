/// 渐变源轨道的后台纯值求值与材料准备，不访问显示目标或维护新缓存owner。
enum GradientEvaluation {
    /// 常量/Hold/端点保留源引用，严格段内只插值双方共有的字节前缀；失败与取消不发布部分表。
    static func colors(_ property: SourceProperty<SourceGradientColors>, at frame: Int64,
                       budget: inout FramePlanBudget) throws -> SourceGradientColors {
        try Task.checkCancellation()
        return try PropertyEvaluation.value(property, at: frame) { keyframe, progress in
            let amount = PropertyEvaluation.eased(progress, by: keyframe.easing, secondDimension: false)
            return try interpolate(keyframe.startValue, keyframe.endValue, progress: amount, budget: &budget)
        }
    }

    /// 用至多四个同源paint候选复用颜色程序；端点/opacity不参与程序身份，命中同样计保活成本。
    static func prepare(_ source: SourceGradient, at frame: Int64, matrix: SceneAffine,
                        reusing candidates: [PreparedGradientColorizer],
                        budget: inout FramePlanBudget) throws -> PreparedGradient {
        try Task.checkCancellation()
        try budget.reserve(stride: 256)
        let value = try colors(source.colors, at: frame, budget: &budget)
        var reused: PreparedGradientColorizer?
        for candidate in candidates.prefix(4) {
            try Task.checkCancellation()
            try budget.reserve(stride: 16)
            if candidate.source === value {
                try budget.reserve(stride: candidate.estimatedBytes)
                reused = candidate
                break
            }
        }
        let colorizer = try reused ?? GradientColorizer.prepare(value, budget: &budget)
        let start = try PropertyEvaluation.point(source.start, at: frame)
        let end = try PropertyEvaluation.point(source.end, at: frame)
        try Task.checkCancellation()
        return PreparedGradient(kind: source.kind, start: start, end: end, matrix: matrix,
            colorizer: colorizer, estimatedBytes: 256 + colorizer.estimatedBytes)
    }

    /// GradientColor::interpolate复制start布局，仅min(count)前缀改变；overshoot字节钳位而非改变位置。
    private static func interpolate(_ first: SourceGradientColors, _ second: SourceGradientColors, progress: Float,
                                    budget: inout FramePlanBudget) throws -> SourceGradientColors {
        guard progress.isFinite else { throw SceneValidator.invalid("unrepresentablePropertyValue") }
        try GradientStopPreparation.validateCounts(first)
        try GradientStopPreparation.validateCounts(second)
        try budget.reserve(stride: 128)
        try budget.reserve(count: first.alphaStops.count, stride: 64)
        try budget.reserve(count: first.colorStops.count, stride: 64)
        var alphas: [SourceAlphaStop] = []
        var colors: [SourceColorStop] = []
        alphas.reserveCapacity(first.alphaStops.count)
        colors.reserveCapacity(first.colorStops.count)
        for (index, stop) in first.alphaStops.enumerated() {
            try Task.checkCancellation()
            try budget.reserve(stride: 16)
            let opacity = try index < second.alphaStops.count
                ? PropertyEvaluation.colorChannel(stop.opacity, second.alphaStops[index].opacity, progress: progress) : stop.opacity
            alphas.append(SourceAlphaStop(position: stop.position, midpoint: stop.midpoint, opacity: opacity))
        }
        for (index, stop) in first.colorStops.enumerated() {
            try Task.checkCancellation()
            try budget.reserve(stride: 16)
            let color = try index < second.colorStops.count
                ? GradientStopPreparation.interpolate(stop.color, second.colorStops[index].color, progress: progress) : stop.color
            colors.append(SourceColorStop(position: stop.position, midpoint: stop.midpoint, color: color))
        }
        try Task.checkCancellation()
        return SourceGradientColors(alphaStops: alphas, colorStops: colors)
    }
}
