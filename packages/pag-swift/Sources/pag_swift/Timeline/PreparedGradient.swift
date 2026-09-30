/// 当前源帧的渐变材料，保留paint局部坐标；不含显示像素、平台对象或GPU资源。
struct PreparedGradient: Sendable {
    /// Linear或Radial的采样映射；不决定颜色程序的身份。
    let kind: SourceGradientKind
    /// paint局部起点，Radial用作圆心。
    let start: ScenePoint
    /// paint局部终点，Radial只使用它与起点的距离。
    let end: ScenePoint
    /// paint所在形状组到图层坐标的累计变换。
    let matrix: SceneAffine
    /// 与显示目标无关的已编译颜色参数，同源不变色值可以保活同一对象。
    let colorizer: PreparedGradientColorizer
    /// 材料外壳及完整保活颜色程序的保守成本，不包括编译临时工作。
    let estimatedBytes: Int
}

/// 一份不可变渐变颜色程序；失败分类也保留边色，供后续先处理几何退化。
final class PreparedGradientColorizer: Sendable {
    /// 已校验源双表的引用身份，避免热路径深比较或重扫stop。
    let source: SourceGradientColors
    /// 原合并表首色，未预乘RGBA；Linear退化及t<=0使用。
    let first: SIMD4<Float>
    /// 原合并表末色，未预乘RGBA；Radial退化及t>=1使用。
    let last: SIMD4<Float>
    /// 解析程序或延后到非退化绘制时处理的不可用状态。
    let result: GradientColorizerResult
    /// 包括source双表与系数的保守持有成本；缓存命中仍需预付。
    let estimatedBytes: Int

    /// 保存完整编译结果；调用方必须已经计费并校验双表，失败不能发布半程序。
    init(source: SourceGradientColors, first: SIMD4<Float>, last: SIMD4<Float>,
         result: GradientColorizerResult, estimatedBytes: Int) {
        self.source = source
        self.first = first
        self.last = last
        self.result = result
        self.estimatedBytes = estimatedBytes
    }
}

/// 颜色准备状态；布局退化的优先级高于后两种解析不可用状态。
enum GradientColorizerResult: Sendable {
    /// 原双表合并后只有一色，直接使用完整RGBA。
    case singleColor
    /// 已编译的有限Float解析参数，不需要纹理查表。
    case analytic(GradientColorizerProgram)
    /// 上游需纹理LUT；首版保留边色，非退化绘制明确未支持。
    case requiresTexture
    /// 系数非有限、无有效区间或源shader末端未定义，不能提交给GPU。
    case invalidPrecision
}

/// TGFX支持的有界解析程序，Single与其他区间保留不同的浮点算式。
enum GradientColorizerProgram: Sendable {
    /// 在0...1使用(1-t)*start+t*end，不从两色推导scale/bias。
    case single(start: SIMD4<Float>, end: SIMD4<Float>)
    /// Dual或Unrolled的至多八段参数，阈值相等时选择右段。
    case intervals([GradientColorInterval])
}

/// 一段t*scale+bias的未预乘RGBA，片元只消费这组小常量。
struct GradientColorInterval: Sendable {
    /// 区间右开上界，最后一段的尾部有效性已由编译器检查。
    let upperBound: Float
    /// 四通道随归一化t变化的有限Float斜率。
    let scale: SIMD4<Float>
    /// 四通道有限Float截距，保持源减乘顺序。
    let bias: SIMD4<Float>
}
