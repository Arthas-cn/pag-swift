/// 文本框附加呈现方式；不修改PAG源排版字段或公开文字样式。
public enum PAGTextOverflow: Sendable, Hashable {
    /// 显式按原始框裁剪，文本仍依上游原规则断行或缩小。
    case clip
    /// 单行超框时按真实字体测宽并以省略号收尾；始终裁剪到原文本框。
    case truncate
    /// 原字号单行超出框宽时按播放器辅助时间水平循环滚动。
    case marquee(PAGMarqueeOptions)
}

/// 跑马灯在合成坐标中的速度、间隔和起步等待，值在构造时完整校验。
public struct PAGMarqueeOptions: Sendable, Hashable {
    /// 每秒移动的正合成点数。
    public let speed: Double
    /// 两份文字之间的非负合成点数。
    public let gap: Double
    /// 首次有效呈现后延迟滚动的非负时间。
    public let initialDelay: PAGTime

    /// 接受有限正速度、有限非负间隔和非负等待；非法值抛对应invalidArgument。
    public init(speed: Double = 30, gap: Double = 24,
                initialDelay: PAGTime = .zero) throws {
        guard speed.isFinite, speed > 0 else { throw PAGError.invalidArgument("marqueeSpeed") }
        guard gap.isFinite, gap >= 0 else { throw PAGError.invalidArgument("marqueeGap") }
        guard initialDelay.microseconds >= 0 else { throw PAGError.invalidArgument("marqueeInitialDelay") }
        self.speed = speed
        self.gap = gap
        self.initialDelay = initialDelay
    }
}
