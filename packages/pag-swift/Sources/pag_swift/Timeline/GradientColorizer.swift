/// TGFX渐变解析参数的后台编译器；不生成纹理，不访问GPU，不缓存跨文档状态。
enum GradientColorizer {
    /// 编译完整双表并保留边色；纹理分支/未定义尾部记录为状态，交后续先判断布局退化。
    static func prepare(_ source: SourceGradientColors, budget: inout FramePlanBudget) throws -> PreparedGradientColorizer {
        try Task.checkCancellation()
        try GradientStopPreparation.validateCounts(source)
        // 源表保活与程序外壳先计费；已有4096/表边界使以下加乘不溢出。
        let sourceBytes = 384 + (source.alphaStops.count + source.colorStops.count) * 64
        try budget.reserve(stride: sourceBytes)
        let merged = try GradientStopPreparation.merge(source, budget: &budget)
        let result: GradientColorizerResult
        if merged.count == 1 { result = .singleColor }
        else { result = try program(normalized(merged, budget: &budget), budget: &budget) }
        let coefficientBytes: Int
        switch result {
        case .analytic(.single): coefficientBytes = 64
        case .analytic(.intervals(let intervals)): coefficientBytes = intervals.count * 64
        case .singleColor, .requiresTexture, .invalidPrecision: coefficientBytes = 0
        }
        try Task.checkCancellation()
        return PreparedGradientColorizer(source: source, first: merged[0].color, last: merged[merged.count - 1].color,
            result: result, estimatedBytes: sourceBytes + coefficientBytes)
    }

    /// GradientShader补0/1端色后单调夹值；原始超过1的位置会保留为重复1，不能提前去重。
    private static func normalized(_ source: [GradientStop], budget: inout FramePlanBudget) throws -> [GradientStop] {
        try budget.reserve(count: source.count + 2, stride: 64)
        var result: [GradientStop] = []
        result.reserveCapacity(source.count + 2)
        if source[0].position != 0 { result.append(GradientStop(position: 0, color: source[0].color)) }
        var previous: Float = 0
        for stop in source {
            try Task.checkCancellation()
            try budget.reserve(stride: 16)
            let position = max(min(stop.position, 1), previous)
            result.append(GradientStop(position: position, color: stop.color))
            previous = position
        }
        if source[source.count - 1].position != 1 {
            result.append(GradientStop(position: 1, color: source[source.count - 1].color))
        }
        return result
    }

    /// MakeColorizer按原列表先计算两端near，再各剥一项；保留Single/Dual的优先级。
    private static func program(_ stops: [GradientStop], budget: inout FramePlanBudget) throws -> GradientColorizerResult {
        try Task.checkCancellation()
        try budget.reserve(count: 2, stride: 16)
        let bottom = near(stops[0].position, stops[1].position)
        let top = near(stops[stops.count - 2].position, stops[stops.count - 1].position)
        let lower = bottom ? 1 : 0
        let upper = stops.count - (top ? 1 : 0)
        let count = upper - lower
        guard count >= 2 else { return .invalidPrecision }
        if count == 2 {
            try budget.reserve(stride: 64)
            return .analytic(.single(start: stops[lower].color, end: stops[lower + 1].color))
        }
        guard count <= 16 else { return .requiresTexture }
        if count == 3 {
            return try dual(stops[lower].color, stops[lower + 1].color,
                stops[lower + 1].color, stops[lower + 2].color, threshold: stops[lower + 1].position, budget: &budget)
        }
        try budget.reserve(stride: 16)
        if count == 4, near(stops[lower + 1].position, stops[lower + 2].position) {
            return try dual(stops[lower].color, stops[lower + 1].color,
                stops[lower + 2].color, stops[lower + 3].color, threshold: stops[lower + 1].position, budget: &budget)
        }
        return try unrolled(stops, range: lower..<upper, budget: &budget)
    }

    /// Dual两段均以0/1为外边界，不能用剥除后的近端位置重新归一化。
    private static func dual(_ first: SIMD4<Float>, _ left: SIMD4<Float>, _ right: SIMD4<Float>, _ last: SIMD4<Float>,
                             threshold: Float, budget: inout FramePlanBudget) throws -> GradientColorizerResult {
        try Task.checkCancellation()
        try budget.reserve(count: 2, stride: 64)
        let firstScale = (left - first) / threshold
        let lastScale = (last - right) / (1 - threshold)
        let lastBias = right - threshold * lastScale
        guard finite(firstScale), finite(lastScale), finite(lastBias) else { return .invalidPrecision }
        return .analytic(.intervals([
            GradientColorInterval(upperBound: threshold, scale: firstScale, bias: first),
            GradientColorInterval(upperBound: 1, scale: lastScale, bias: lastBias)
        ]))
    }

    /// Unrolled每轮先判断已有八段，再跳near宽度；末尾未定义区间不能外推或改为透明成功。
    private static func unrolled(_ stops: [GradientStop], range: Range<Int>,
                                 budget: inout FramePlanBudget) throws -> GradientColorizerResult {
        try budget.reserve(count: 8, stride: 64)
        var intervals: [GradientColorInterval] = []
        intervals.reserveCapacity(8)
        for index in range.dropLast() {
            try Task.checkCancellation()
            try budget.reserve(count: 2, stride: 16)
            guard intervals.count < 8 else { return .requiresTexture }
            let first = stops[index], last = stops[index + 1]
            let width = last.position - first.position
            if near(width, 0) { continue }
            let scale = (last.color - first.color) / width
            let bias = first.color - first.position * scale
            guard finite(scale), finite(bias) else { return .invalidPrecision }
            intervals.append(GradientColorInterval(upperBound: last.position, scale: scale, bias: bias))
        }
        guard let last = intervals.last, intervals.count == 8 || last.upperBound >= 1 else { return .invalidPrecision }
        return .analytic(.intervals(intervals))
    }

    /// TGFX FloatNearlyEqual/Zero的绝对阈值，等号也属于near，不能替换为相对误差。
    private static func near(_ first: Float, _ second: Float) -> Bool { abs(first - second) <= 1 / 4096 }

    /// 四通道固定成本的有限性检查；非有限程序只记录invalidPrecision供布局退化之后处理。
    private static func finite(_ value: SIMD4<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite && value.w.isFinite
    }
}
