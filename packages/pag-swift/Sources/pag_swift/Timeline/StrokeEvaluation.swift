import Foundation

/// CreateDashEffect与固定PathKit的有效虚线参数；空effect通过nil表达，不能与系统几何失败混淆。
struct StrokeDashPattern: Sendable, Equatable {
    /// 正常化后的偶数间隔，保持零项和原始顺序，最多十六项。
    let intervals: [Double]
    /// Float规范化后的相位，数学范围为0..<period；每个子路径重新使用此相位。
    let phase: Double
    /// 按Float顺序累加得到的正有限周期。
    let period: Double

    /// 原列表最多八项；奇数整体重复，源码定义的无效effect返回nil，非有限输入/取消明确失败。
    static func make(intervals: [Double], phase: Double) throws -> StrokeDashPattern? {
        try Task.checkCancellation()
        guard intervals.count <= 8 else { throw SceneValidator.invalid("invalidStrokeDashCount") }
        guard !intervals.isEmpty else { return nil }
        var values: [Float] = []
        for value in intervals {
            try Task.checkCancellation()
            values.append(try StrokeEvaluation.finite(value))
        }
        var phase = try StrokeEvaluation.finite(phase)
        if values.count % 2 != 0 { values += values }
        var period: Float = 0
        for value in values {
            // MakeDash拒绝这种effect后PAG继续实线，不能改为取绝对值或丢弃负项。
            guard value >= 0 else { return nil }
            period += value
        }
        guard period > 0, period.isFinite else { return nil }
        if phase < 0 {
            phase = -phase
            if phase > period { phase = phase.truncatingRemainder(dividingBy: period) }
            phase = period - phase
            if phase == period { phase = 0 }
        } else if phase >= period {
            phase = phase.truncatingRemainder(dividingBy: period)
        }
        return StrokeDashPattern(intervals: values.map(Double.init), phase: Double(phase), period: Double(period))
    }
}

/// 当前帧已正常化的描边几何参数；颜色/alpha不属于几何，不应让它们使网格缓存失效。
struct StrokeStyle: Sendable, Equatable {
    /// 正Float来源宽度；非正值已在paint准备前排除。
    let width: Double
    /// 开放端点的几何规则，退化处理仍由中心线消费者负责。
    let cap: SourceLineCap
    /// 已应用miter特殊规则的接角方式。
    let join: SourceLineJoin
    /// 负原值已回落到4；非miter接角不使用此数值。
    let miterLimit: Double
    /// nil为实线，包括源码允许的无效dash-effect回落。
    let dashes: StrokeDashPattern?

    /// 固定TGFX的极小正宽分支；此时保留dash后的中心路径作为fill，不扩描边。
    var isHairline: Bool { width <= 1.0 / 4096 }
}

/// 普通Stroke在一个源合成帧的paint结果；仍是纯值，不创建几何或GPU对象。
struct EvaluatedStroke: Sendable {
    /// 只影响outline的样式，与颜色动画分离。
    let style: StrokeStyle
    /// 当前帧未预乘的RGB。
    let color: SceneColor
    /// 0...1中的正自身alpha，不包含组与图层透明度。
    let opacity: Double
    /// 此paint相对同组已有内容的上下关系。
    let compositeOrder: ShapeCompositeOrder
}

/// 对完整描边轨道做无共享游标的后台纯值求值；几何坐标与平台路径留给渲染阶段。
enum StrokeEvaluation {
    /// 用源合成帧求值；透明或非正宽返回nil，溢出和取消不发布不完整样式。
    static func evaluate(_ source: SourceStroke, at frame: Int64) throws -> EvaluatedStroke? {
        try Task.checkCancellation()
        let opacity = try PropertyEvaluation.opacity(source.opacity, at: frame)
        guard opacity > 0 else { return nil }
        guard let style = try style(width: source.width, miterLimit: source.miterLimit, cap: source.cap,
                                    join: source.join, dashes: source.dashes, at: frame) else { return nil }
        let color = try PropertyEvaluation.color(source.color, at: frame)
        try Task.checkCancellation()
        return EvaluatedStroke(style: style, color: color, opacity: Double(opacity) / 255,
                               compositeOrder: source.compositeOrder)
    }

    /// 普通与渐变描边共用几何样式；非正宽跳过，其余非法值和取消原样失败，不求值颜色。
    static func style(width: SourceProperty<Double>, miterLimit: SourceProperty<Double>,
                      cap: SourceLineCap, join: SourceLineJoin, dashes: SourceDashes?, at frame: Int64) throws -> StrokeStyle? {
        try Task.checkCancellation()
        let width = try finite(PropertyEvaluation.scalar(width, at: frame))
        guard width > 0 else { return nil }
        let rawMiter = try finite(PropertyEvaluation.scalar(miterLimit, at: frame))
        let miter: Float = rawMiter < 0 ? 4 : rawMiter
        // 只有Miter join受斜接限制影响；Round不能因为limit为0而变成Bevel。
        let join: SourceLineJoin = join == .miter && miter <= 1 ? .bevel : join
        var pattern: StrokeDashPattern?
        if let raw = dashes {
            var intervals: [Double] = []
            for property in raw.intervals {
                try Task.checkCancellation()
                intervals.append(try PropertyEvaluation.scalar(property, at: frame))
            }
            pattern = try StrokeDashPattern.make(intervals: intervals, phase: PropertyEvaluation.scalar(raw.offset, at: frame))
        }
        try Task.checkCancellation()
        return StrokeStyle(width: Double(width), cap: cap, join: join, miterLimit: Double(miter), dashes: pattern)
    }

    /// 保持Float来源的可表示边界；常量和纯语义测试同样不能把非有限值送到几何阶段。
    static func finite(_ value: Double) throws -> Float {
        let result = Float(value)
        guard result.isFinite else { throw SceneValidator.invalid("unrepresentablePropertyValue") }
        return result
    }
}
