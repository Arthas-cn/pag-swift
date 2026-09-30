/// 普通描边端点的源码枚举；原始数值与file.h一致，不映射未知值。
enum SourceLineCap: UInt8, Sendable {
    /// 开放线段在端点停止，不向切线方向延伸。
    case butt = 0
    /// 在开放端点绘制半径为半线宽的圆头。
    case round = 1
    /// 在开放端点沿切线延伸半线宽，退化无切向时使用轴向方形。
    case square = 2
}

/// 普通描边相邻线段的接角方式；闭合缝也使用此规则。
enum SourceLineJoin: UInt8, Sendable {
    /// 延长两侧边界形成尖角，超过miterLimit后退为bevel。
    case miter = 0
    /// 用圆弧连接相邻外侧边界。
    case round = 1
    /// 直接连接两侧外缘，形成削平的接角。
    case bevel = 2
}

/// paint相对同组已有绘制内容的顺序；不改变中心线累计顺序。
enum ShapeCompositeOrder: UInt8, Sendable {
    /// 新paint位于此前内容下方，是文件缺省值。
    case belowPrevious = 0
    /// 新paint位于此前内容上方。
    case abovePrevious = 1
}

/// 文件中的原始虚线轨道；解码层不复制奇数项或修正负数。
struct SourceDashes: Sendable {
    /// 虚线相位轨道，缺省为0；负相位由消费层处理。
    let offset: SourceProperty<Double>
    /// 一到八个Float轨道，缺省单项长度为10；零与负数原样保留。
    let intervals: [SourceProperty<Double>]

    /// 保留完整已读轨道，拒绝超出ReadDashes三位计数范围的内部构造。
    init(offset: SourceProperty<Double>, intervals: [SourceProperty<Double>]) throws {
        guard (1...8).contains(intervals.count) else { throw SceneValidator.invalid("invalidStrokeDashCount") }
        self.offset = offset
        self.intervals = intervals
    }

    /// 相位或任一间隔是否随源合成帧改变；最多检查八条间隔。
    var isAnimated: Bool { offset.isAnimated || intervals.contains(where: \.isAnimated) }
}

/// 已完整读取的普通Stroke属性；只保留纯值轨道，不创建路径或平台绘制对象。
struct SourceStroke: Sendable {
    /// 与同组已有内容的上下关系，未知编码在读取时拒绝。
    let compositeOrder: ShapeCompositeOrder
    /// 开放路径的端点规则。
    let cap: SourceLineCap
    /// 折线与闭合缝的接角规则。
    let join: SourceLineJoin
    /// 原始斜接限制轨道，负值的默认回落只在消费时发生。
    let miterLimit: SourceProperty<Double>
    /// 未预乘RGB轨道，缺省为White，各通道共用时间缓动。
    let color: SourceProperty<SceneColor>
    /// 自身透明度轨道，范围0...255，不包含组或图层alpha。
    let opacity: SourceProperty<UInt8>
    /// Float线宽轨道，非正值在当前时刻不生成paint。
    let width: SourceProperty<Double>
    /// nil表示没有Custom虚线属性，不能为它读取额外offset内容。
    let dashes: SourceDashes?

    /// 任一几何或paint属性依赖采样帧；具体几何共享不以颜色动画作为失效理由。
    var isAnimated: Bool {
        miterLimit.isAnimated || color.isAnimated || opacity.isAnimated || width.isAnimated || dashes?.isAnimated == true
    }
}
