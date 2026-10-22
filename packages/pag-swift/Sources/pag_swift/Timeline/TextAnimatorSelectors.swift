import Foundation

/// 把tag71/80的不可变轨道转换成当帧逐字形因子；不接触字体或GPU资源。
enum TextAnimatorSelectors {
    /// 按源选择器顺序叠加因子；空选择器对所有可布局字形返回1。
    static func factors(_ selectors: [SourceTextSelector], count: Int, at frame: Int64,
                        budget: inout FramePlanBudget) throws -> [Float] {
        try Task.checkCancellation()
        try budget.reserve(count: count, stride: 16)
        guard count > 0 else { return [] }
        var factors = Array(repeating: Float(1), count: count)
        for (selectorIndex, selector) in selectors.enumerated() {
            try Task.checkCancellation()
            let values: [Float]
            let mode: UInt8
            switch selector {
            case .range(let source):
                mode = try discreteByte(source.mode, at: frame)
                values = try range(source, count: count, at: frame, budget: &budget)
            case .wiggly(let source):
                mode = try discreteByte(source.mode, at: frame)
                values = try wiggly(source, count: count, at: frame, budget: &budget)
            }
            for index in factors.indices {
                try Task.checkCancellation()
                let old = factors[index]
                let value = values[index]
                let next: Float
                // 第一个非Subtract选择器直接取自身值；Subtract始终在初始因子1上计算。
                if selectorIndex == 0 && mode != 2 { next = value }
                else {
                    switch mode {
                    case 2: next = old * (value >= 0 ? 1 - value : -1 - value)
                    case 3: next = old * value
                    case 4: next = min(old, value)
                    case 5: next = max(old, value)
                    case 6: next = abs(old - value)
                    default: next = old + value
                    }
                }
                guard next.isFinite else { throw SceneValidator.invalid("unrepresentableTextAnimatorFactor") }
                factors[index] = min(max(next, -1), 1)
            }
        }
        return factors
    }

    /// 离散UInt8轨道在段内取起点，端点由共同PropertyEvaluation处理。
    static func discreteByte(_ property: SourceProperty<UInt8>, at frame: Int64) throws -> UInt8 {
        try PropertyEvaluation.value(property, at: frame) { segment, _ in segment.startValue }
    }

    /// UInt16种子沿SimpleProperty的Float缓动求值并截为合法整数。
    private static func seed(_ property: SourceProperty<UInt16>, at frame: Int64) throws -> UInt16 {
        try PropertyEvaluation.value(property, at: frame) { segment, progress in
            let amount = PropertyEvaluation.eased(progress, by: segment.easing, secondDimension: false)
            let result = Float(segment.startValue) + (Float(segment.endValue) - Float(segment.startValue)) * amount
            guard result.isFinite else { throw SceneValidator.invalid("unrepresentableTextAnimatorSeed") }
            return UInt16(min(max(result, 0), Float(UInt16.max)))
        }
    }

    /// 按RangeSelectorRenderer取区间、打乱后的索引和六种形状，再乘amount。
    private static func range(_ source: SourceTextRangeSelector, count: Int, at frame: Int64,
                              budget: inout FramePlanBudget) throws -> [Float] {
        var start = Float(try PropertyEvaluation.scalar(source.start, at: frame))
        var end = Float(try PropertyEvaluation.scalar(source.end, at: frame))
        let offset = Float(try PropertyEvaluation.scalar(source.offset, at: frame))
        start += offset
        end += offset
        if start > end { swap(&start, &end) }
        let amount = Float(try PropertyEvaluation.scalar(source.amount, at: frame))
        let easeHigh = Float(try PropertyEvaluation.scalar(source.easeHigh, at: frame))
        let easeLow = Float(try PropertyEvaluation.scalar(source.easeLow, at: frame))
        guard start.isFinite, end.isFinite, amount.isFinite, easeHigh.isFinite, easeLow.isFinite else {
            throw SceneValidator.invalid("unrepresentableTextAnimatorRange")
        }
        try budget.reserve(count: count, stride: 16)
        let order = try source.randomizeOrder ? randomOrder(count: count, seed: seed(source.randomSeed, at: frame),
                                                             budget: &budget) : Array(0..<count)
        var values: [Float] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let textStart = Float(order[index]) / Float(count)
            let textEnd = Float(order[index] + 1) / Float(count)
            let raw: Float
            switch source.shape {
            case 1: raw = ((textStart + textEnd) * 0.5 - start) / (end - start)
            case 2: raw = (end - (textStart + textEnd) * 0.5) / (end - start)
            case 3: raw = triangle(textStart: textStart, textEnd: textEnd,
                                   start: start, end: end, high: easeHigh, low: easeLow)
            case 4: raw = round(textStart: textStart, textEnd: textEnd, start: start, end: end)
            case 5: raw = smooth(textStart: textStart, textEnd: textEnd, start: start, end: end)
            default:
                if textStart >= end || textEnd <= start { raw = 0 }
                else { raw = (min(textEnd, end) - max(textStart, start)) / (textEnd - textStart) }
            }
            guard raw.isFinite else { throw SceneValidator.invalid("unrepresentableTextAnimatorRange") }
            let factor = min(max(raw, 0), 1) * amount
            guard factor.isFinite else { throw SceneValidator.invalid("unrepresentableTextAnimatorFactor") }
            values.append(factor)
        }
        return values
    }

    /// 摆动选择器沿用上游明确标注为近似AE的双余弦公式与min/max映射。
    private static func wiggly(_ source: SourceTextWigglySelector, count: Int, at frame: Int64,
                               budget: inout FramePlanBudget) throws -> [Float] {
        let maximum = Float(try PropertyEvaluation.scalar(source.maxAmount, at: frame))
        let minimum = Float(try PropertyEvaluation.scalar(source.minAmount, at: frame))
        let wiggles = Float(try PropertyEvaluation.scalar(source.wigglesPerSecond, at: frame))
        let correlation = Float(try PropertyEvaluation.scalar(source.correlation, at: frame))
        let temporal = Float(try PropertyEvaluation.scalar(source.temporalPhase, at: frame))
        let spatial = Float(try PropertyEvaluation.scalar(source.spatialPhase, at: frame))
        let randomSeed = Float(try seed(source.randomSeed, at: frame))
        try budget.reserve(count: count, stride: 8)
        var values: [Float] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let temporalSeed = wiggles / 2 * (Float(frame) + temporal / 30) / 24
            let spatialSeed = (13.73 * (1 - correlation) * Float(index) + spatial / 80) / 21.13
            let phase = (spatialSeed + temporalSeed + randomSeed / 3.13) * 2 * Float.pi
            let wave = min(max(cos(phase) * cos(phase / 7 + Float.pi / 5), -1), 1)
            let value = (wave + 1) / 2 * (maximum - minimum) + minimum
            guard value.isFinite else { throw SceneValidator.invalid("unrepresentableTextAnimatorFactor") }
            values.append(value)
        }
        return values
    }

    /// 以局部Park–Miller状态复现当前Darwin rand/rand_r序列，避免上游全局srand竞态。
    private static func randomOrder(count: Int, seed: UInt16,
                                    budget: inout FramePlanBudget) throws -> [Int] {
        try budget.reserve(count: count, stride: 32)
        var state = seed == 0 ? UInt64(123_459_876) : UInt64(seed)
        var pairs: [(value: UInt64, index: Int)] = []
        for index in 0..<count {
            try Task.checkCancellation()
            state = state * 16_807 % 2_147_483_647
            pairs.append((state, index))
        }
        pairs.sort { $0.value == $1.value ? $0.index < $1.index : $0.value < $1.value }
        var order = pairs.map(\.index)
        if seed == 0 && count > 1 {
            // 上游对零种子另用实测AE首字形表修正随机顺序，随后交换避免重复索引。
            let first = count <= 2 ? 0 : count <= 4 ? 2 : count <= 5 ? 4 : count <= 20 ? 5
                : count <= 69 ? 20 : count <= 127 ? 69 : count <= 206 ? 127 : 205
            if let position = order.firstIndex(of: min(first, count - 1)) { order.swapAt(0, position) }
        }
        return order
    }

    /// 三角形两侧分别按上游easeHigh/easeLow控制点求根，再取三次曲线y。
    private static func triangle(textStart: Float, textEnd: Float, start: Float, end: Float,
                                 high: Float, low: Float) -> Float {
        let x = Double((textStart + textEnd) * 0.5)
        let middle = Double((start + end) * 0.5)
        if x < Double(start) || x > Double(end) { return 0 }
        let x1 = x <= middle ? Double(start) : Double(end)
        let step = middle - x1
        let x2 = low >= 0 ? x1 + Double(low) * step : x1
        let y2 = low >= 0 ? 0.0 : Double(-low)
        let x3 = high >= 0 ? middle - Double(high) * step : middle
        let y3 = high >= 0 ? 1.0 : 1 + Double(high)
        let a = -x1 + 3 * x2 - 3 * x3 + middle
        let b = 3 * (x1 - 2 * x2 + x3)
        let c = 3 * (-x1 + x2)
        let d = x1 - x
        let t = cubicRoots(a, b, c, d).first(where: { (0...1).contains($0) || abs($0 - 1) <= 1e-6 }) ?? 0
        let inverse = 1 - t
        return Float(3 * inverse * inverse * t * y2 + 3 * inverse * t * t * y3 + t * t * t)
    }

    /// 按上游范盛金分支给出三次方程的实根，保持返回顺序供三角形选择。
    private static func cubicRoots(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> [Double] {
        guard a != 0 else { return [] }
        let aa = b * b - 3 * a * c
        let bb = b * c - 9 * a * d
        let cc = c * c - 3 * b * d
        let delta = bb * bb - 4 * aa * cc
        if aa == 0 && bb == 0 { return [-b / (3 * a)] }
        if delta == 0 && aa != 0 {
            let k = bb / aa
            return [-b / a + k, -0.5 * k]
        }
        if delta > 0 {
            let y1 = aa * b + 1.5 * a * (-bb + sqrt(delta))
            let y2 = aa * b + 1.5 * a * (-bb - sqrt(delta))
            return [(-b - cbrt(y1) - cbrt(y2)) / (3 * a)]
        }
        if delta < 0 && aa > 0 {
            let value = (aa * b - 1.5 * a * bb) / (aa * sqrt(aa))
            if -1 < value && value < 1 {
                let theta = acos(value)
                let root = sqrt(aa)
                let cosine = cos(theta / 3)
                let sine = sin(theta / 3)
                return [(-b - 2 * root * cosine) / (3 * a),
                        (-b + root * (cosine + sqrt(3) * sine)) / (3 * a),
                        (-b + root * (cosine - sqrt(3) * sine)) / (3 * a)]
            }
        }
        return []
    }

    /// 圆弧截面的根号高度，区间外保持零。
    private static func round(textStart: Float, textEnd: Float, start: Float, end: Float) -> Float {
        let center = (textStart + textEnd) * 0.5
        if center >= end || center <= start { return 0 }
        let radius = (end - start) * 0.5
        let delta = (start + end) * 0.5 - center
        return sqrt(max(radius * radius - delta * delta, 0)) / radius
    }

    /// 平滑轮廓使用固定(0.5,0)/(0.5,1)时间曲线，不为每个字形分配折线。
    private static func smooth(textStart: Float, textEnd: Float, start: Float, end: Float) -> Float {
        let center = (textStart + textEnd) * 0.5
        if center >= end || center <= start { return 0 }
        let middle = (start + end) * 0.5
        let x = center < middle ? (center - start) / (middle - start) : (end - center) / (end - middle)
        var low: Float = 0
        var high: Float = 1
        for _ in 0..<24 {
            let t = (low + high) * 0.5
            let inverse = 1 - t
            let curveX = 1.5 * inverse * inverse * t + 1.5 * inverse * t * t + t * t * t
            if curveX < x { low = t } else { high = t }
        }
        let t = (low + high) * 0.5
        return 3 * (1 - t) * t * t + t * t * t
    }
}
