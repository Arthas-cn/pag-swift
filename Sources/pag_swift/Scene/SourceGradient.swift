/// 首批有完整绘制合同的形状渐变类型；其他源码枚举仍由读取器明确拒绝。
enum SourceGradientKind: UInt8, Sendable {
    /// 沿start到end的源局部方向变化，显示时保留paint矩阵。
    case linear = 0
    /// 以start为圆心、两点距离为半径，没有额外焦点字段。
    case radial = 1
}

/// 源透明度色标；位置保留编码可表示范围，中点只接受当前支持的0...1。
struct SourceAlphaStop: Sendable, Equatable {
    /// UInt16乘源Float精度后的坐标，可超过1；消费时才进行端点钳制。
    let position: Float
    /// 当前项到下一项之间达到半透明度的相对位置，末项同样保留原值。
    let midpoint: Float
    /// 未与paint或图层透明度相乘的0...255通道值。
    let opacity: UInt8
}

/// 源RGB色标，与alpha表分开保存，不能在解码时提前预乘或展开中点。
struct SourceColorStop: Sendable, Equatable {
    /// 原Float位置；同一表在读取后严格升序，两张表之间允许同位置。
    let position: Float
    /// 当前项到下一项的颜色中点，合法支持范围0...1。
    let midpoint: Float
    /// 三字节源色，透明度来自独立的alpha表。
    let color: SceneColor
}

/// 一份不可变双表颜色值；引用身份供常量/Hold材料复用，不实现逐帧深数组比较。
final class SourceGradientColors: Sendable {
    /// 非空且位置严格升序的透明度表；正式读取最多4096项。
    let alphaStops: [SourceAlphaStop]
    /// 非空且位置严格升序的RGB表；每个关键帧可有不同长度。
    let colorStops: [SourceColorStop]

    /// 保存已校验的完整双表；读取器负责预算与排序，纯语义构造同样须满足上述不变量。
    init(alphaStops: [SourceAlphaStop], colorStops: [SourceColorStop]) {
        self.alphaStops = alphaStops
        self.colorStops = colorStops
    }
}

/// Fill/Stroke共用的源渐变属性，不携带平台颜色或GPU资源。
struct SourceGradient: Sendable {
    /// 不随帧变化的布局枚举，未知编码不降级为Linear。
    let kind: SourceGradientKind
    /// paint局部起点轨道；Radial用它作为圆心。
    let start: SourceProperty<ScenePoint>
    /// paint局部终点轨道；Radial只用与起点的距离。
    let end: SourceProperty<ScenePoint>
    /// 原始双表轨道，中间值的布局继承起始关键值。
    let colors: SourceProperty<SourceGradientColors>
    /// 自身0...255透明度轨道，不包含组与图层alpha。
    let opacity: SourceProperty<UInt8>

    /// 任一共有属性依赖采样帧；颜色相同的显式轨道也属于动画。
    var isAnimated: Bool { start.isAnimated || end.isAnimated || colors.isAnimated || opacity.isAnimated }
}

/// 已读取的NonZero渐变填充，只保存源属性，不求值或生成路径。
struct SourceGradientFill: Sendable {
    /// 此paint相对同组此前内容的覆盖关系。
    let compositeOrder: ShapeCompositeOrder
    /// 完整的布局、颜色与透明度轨道。
    let gradient: SourceGradient
}

/// 已读取的渐变描边；几何参数与普通Stroke使用同一源枚举和dash模型。
struct SourceGradientStroke: Sendable {
    /// Below/Above不改变中心线累计顺序。
    let compositeOrder: ShapeCompositeOrder
    /// 描边轮廓内使用的源材料，颜色不会改变几何身份。
    let gradient: SourceGradient
    /// 开放中心线的端点规则。
    let cap: SourceLineCap
    /// 相邻中心线与闭合缝的接角规则。
    let join: SourceLineJoin
    /// 未正常化的斜接限制，消费时处理负值回落。
    let miterLimit: SourceProperty<Double>
    /// 源Float宽度，非正值在消费时跳过paint。
    let width: SourceProperty<Double>
    /// nil表示没有Custom dash，读取时不凭空补offset。
    let dashes: SourceDashes?

    /// 材料、宽度、miter或dash任一轨道变化都需要源帧采样。
    var isAnimated: Bool {
        gradient.isAnimated || miterLimit.isAnimated || width.isAnimated || dashes?.isAnimated == true
    }
}
