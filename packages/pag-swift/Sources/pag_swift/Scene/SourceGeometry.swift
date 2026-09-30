/// 场景坐标中的有限二维向量；允许负坐标与零缩放，不使用 UI 框架对象。
struct ScenePoint: Sendable, Equatable {
    /// 水平方向的坐标或缩放分量。
    let x: Double
    /// 垂直方向的坐标或缩放分量。
    let y: Double
    /// 位移和锚点的默认原点。
    static let zero = ScenePoint(x: 0, y: 0)
    /// 缩放的默认单位向量。
    static let one = ScenePoint(x: 1, y: 1)
}

/// 解码层保留的 RGB 字节；透明度由所属属性独立保存。
struct SceneColor: Sendable, Equatable {
    /// 未预乘的红色通道，范围 0...255。
    let red: UInt8
    /// 未预乘的绿色通道，范围 0...255。
    let green: UInt8
    /// 未预乘的蓝色通道，范围 0...255。
    let blue: UInt8
    /// FillTag 在颜色属性缺省时指定的红色。
    static let defaultFill = SceneColor(red: 255, green: 0, blue: 0)
}

/// 单时刻已解析的二维变换值；图层与形状组从各自轨道求值后生成。
struct SourceTransform: Sendable, Equatable {
    /// 变换围绕的图层局部锚点。
    let anchor: ScenePoint
    /// 在父坐标系中的平移。
    let position: ScenePoint
    /// 两轴缩放；负值表示翻转，零值合法。
    let scale: ScenePoint
    /// 旋转角度，单位沿用 PAG 的度。
    let rotation: Double
    /// 图层不透明度，0 完全透明、255 完全不透明。
    let opacity: UInt8
}

/// 形状组比图层多出斜切属性，保留原始参数供求值层确定矩阵顺序。
struct SourceShapeTransform: Sendable {
    /// 锚点、位置、缩放、旋转和透明度。
    let base: SourceTransform
    /// 斜切角度，单位为度。
    let skew: Double
    /// 斜切轴角度，单位为度。
    let skewAxis: Double
}

/// 有源码证据的形状元素；排列顺序保留文件语义，路径可随合成帧形变，不在解码时栅格化。
indirect enum SourceShape: Sendable {
    /// 具有局部变换的形状组；子元素按编码顺序排列，普通混合。
    case group(SourceShapeTransformProperties, [SourceShape])
    /// 矩形路径的绕序与完整尺寸、中心位置、圆角轨道。
    case rectangle(SourceRectangle)
    /// 椭圆路径的有符号尺寸和中心轨道，正式文件入口须先通过显示验收。
    case ellipse(SourceEllipse)
    /// 星形或多边形的完整参数轨道，在后台几何准备时展开路径。
    case polyStar(SourcePolyStar)
    /// 静态或逐帧形变的路径属性；时间属于源合成，填充由之后的paint元素决定。
    case path(SourceProperty<SourcePath>)
    /// 普通混合、同组下方合成、非零绕数填充；颜色与透明度独立。
    case fill(SourceFill)
    /// 普通描边的完整轨道；准备时求值样式和覆盖顺序。
    case stroke(SourceStroke)
    /// Linear/Radial的NonZero材料；正式字节入口在显示闭包通过后开放。
    case gradientFill(SourceGradientFill)
    /// 与普通描边共用几何规范化，颜色独立缓存。
    case gradientStroke(SourceGradientStroke)
}
