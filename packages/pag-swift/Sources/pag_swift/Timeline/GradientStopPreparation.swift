/// GradientPaint展开与合并后的一个未预乘色标，位置在TGFX规范化前保留源Float。
struct GradientStop: Sendable {
    /// 源生成顺序的位置，允许重复、超过1及中点舍入造成的局部一ULP倒序。
    let position: Float
    /// 字节插值/截断之后除255得到的RGBA，不预乘alpha。
    let color: SIMD4<Float>
}

/// 源双表到RGBA表的后台一次性编译；每步先计费并检查取消，不进入Metal每draw热路径。
enum GradientStopPreparation {
    /// 按GradientPaint先展开两表中点，再双游标合并；错误、预算和取消不返回前缀。
    static func merge(_ source: SourceGradientColors, budget: inout FramePlanBudget) throws -> [GradientStop] {
        try Task.checkCancellation()
        try validateCounts(source)
        let colors = try expanded(source.colorStops, position: \.position, midpoint: \.midpoint, value: \.color,
                                  interpolate: interpolate, budget: &budget)
        let alphas = try expanded(source.alphaStops, position: \.position, midpoint: \.midpoint, value: \.opacity,
                                  interpolate: PropertyEvaluation.colorChannel, budget: &budget)
        try budget.reserve(count: colors.count + alphas.count, stride: 64)
        var result: [GradientStop] = []
        result.reserveCapacity(colors.count + alphas.count)
        var colorIndex = 0, alphaIndex = 0
        while colorIndex < colors.count && alphaIndex < alphas.count {
            try Task.checkCancellation()
            // 一次输出加至多两次位置比较；字节插值是固定四通道工作，不依赖表长。
            try budget.reserve(count: 3, stride: 16)
            let color = colors[colorIndex], alpha = alphas[alphaIndex]
            if color.position == alpha.position {
                result.append(stop(color.position, color.value, alpha.value))
                colorIndex += 1
                alphaIndex += 1
            } else if color.position < alpha.position {
                let opacity: UInt8
                if alphaIndex > 0 {
                    let previous = alphas[alphaIndex - 1]
                    let amount = (color.position - previous.position) / (alpha.position - previous.position)
                    opacity = try PropertyEvaluation.colorChannel(previous.value, alpha.value, progress: amount)
                } else { opacity = alpha.value }
                result.append(stop(color.position, color.value, opacity))
                colorIndex += 1
            } else {
                let rgb: SceneColor
                if colorIndex > 0 {
                    let previous = colors[colorIndex - 1]
                    let amount = (alpha.position - previous.position) / (color.position - previous.position)
                    rgb = try interpolate(previous.value, color.value, progress: amount)
                } else { rgb = color.value }
                result.append(stop(alpha.position, rgb, alpha.value))
                alphaIndex += 1
            }
        }
        // 一张表先耗尽后，另一张表的尾项使用已耗尽表的末值，不能外推斜率。
        while colorIndex < colors.count {
            try Task.checkCancellation()
            try budget.reserve(stride: 16)
            let color = colors[colorIndex]
            result.append(stop(color.position, color.value, alphas[alphas.count - 1].value))
            colorIndex += 1
        }
        while alphaIndex < alphas.count {
            try Task.checkCancellation()
            try budget.reserve(stride: 16)
            let alpha = alphas[alphaIndex]
            result.append(stop(alpha.position, colors[colors.count - 1].value, alpha.value))
            alphaIndex += 1
        }
        try Task.checkCancellation()
        return result
    }

    /// 即使由纯语义模型构造也保持同一非空/4096资源边界，乘加和数组索引才有有限上界。
    static func validateCounts(_ source: SourceGradientColors) throws {
        guard source.alphaStops.isEmpty == false, source.colorStops.isEmpty == false else {
            throw SceneValidator.invalid("emptyGradientStops")
        }
        guard source.alphaStops.count <= 4096, source.colorStops.count <= 4096 else {
            throw PAGError.resourceLimitExceeded("maximumGradientStops")
        }
    }

    /// RGB保持三个UInt8通道的Float插值和截断；供源动画与midpoint/合并共用。
    static func interpolate(_ first: SceneColor, _ second: SceneColor, progress: Float) throws -> SceneColor {
        try SceneColor(red: PropertyEvaluation.colorChannel(first.red, second.red, progress: progress),
            green: PropertyEvaluation.colorChannel(first.green, second.green, progress: progress),
            blue: PropertyEvaluation.colorChannel(first.blue, second.blue, progress: progress))
    }

    /// ConvertColorStop/ConvertAlphaStop共用布局，原表严格升序，midpoint0/1产生的等位置必须保留。
    private static func expanded<Source, Value>(_ source: [Source], position: (Source) -> Float,
        midpoint: (Source) -> Float, value: (Source) -> Value,
        interpolate: (Value, Value, Float) throws -> Value,
        budget: inout FramePlanBudget) throws -> [GradientValueStop<Value>] {
        // 调用者已限制每表1...4096；最多2n-1项，先给临时存储预付。
        try budget.reserve(count: source.count * 2 - 1, stride: 64)
        var result: [GradientValueStop<Value>] = []
        result.reserveCapacity(source.count * 2 - 1)
        var previous: Float = -1
        for (index, item) in source.enumerated() {
            try Task.checkCancellation()
            try budget.reserve(count: 3, stride: 16)
            let point = position(item), middle = midpoint(item)
            guard point.isFinite, point >= 0, point > previous else {
                throw PAGError.renderingFailure("gradientPrecision")
            }
            guard middle.isFinite, (0...1).contains(middle) else {
                throw PAGError.unsupportedFeature("gradientMidpointRange")
            }
            previous = point
            result.append(GradientValueStop(position: point, value: value(item)))
            if middle != 0.5, index + 1 < source.count {
                try Task.checkCancellation()
                try budget.reserve(stride: 16)
                let next = source[index + 1]
                let midpointPosition = point + (position(next) - point) * middle
                guard midpointPosition.isFinite else { throw PAGError.renderingFailure("gradientPrecision") }
                result.append(try GradientValueStop(position: midpointPosition, value: interpolate(value(item), value(next), 0.5)))
            }
        }
        return result
    }

    /// ToTGFX逐通道除255；透明色保留RGB，不能在合并时先预乘。
    private static func stop(_ position: Float, _ color: SceneColor, _ opacity: UInt8) -> GradientStop {
        GradientStop(position: position, color: SIMD4(Float(color.red) / 255, Float(color.green) / 255,
                                                     Float(color.blue) / 255, Float(opacity) / 255))
    }
}

/// 中点展开暂存的单表项，不持有显示数据；Value为RGB或UInt8 alpha。
private struct GradientValueStop<Value> {
    /// 原位置或按源Float次序求出的中点位置。
    let position: Float
    /// 尚未与另一张表合并的字节通道值。
    let value: Value
}
