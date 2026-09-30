/// 解码后的基础图层内容；只保存源记录，不复制预合成的资源。
enum SourceLayerContent: Sendable {
    /// 不绘制像素，但仍能参与父变换链的控制层。
    case null
    /// 具有正尺寸的单色区域。
    case solid(size: PAGSize, color: SceneColor)
    /// 按文件顺序排列的静态形状操作。
    case shape([SourceShape])
    /// 完整静态文字与原始排版参数；编辑时只覆盖可编辑样式。
    case text(SourceText)
    /// 文件级图片资源 ID，验证阶段确保存在。
    case image(UInt32)
    /// 引用合成的源 ID，以及在当前父时间轴中的合成起始帧。
    case precomposition(id: UInt32, startFrame: Int64)

    /// 映射到公开语义类别，不把控制层伪装为可绘制内容。
    var kind: PAGLayerKind {
        switch self {
        case .null: .null
        case .solid: .solid
        case .shape: .shape
        case .text: .text
        case .image: .image
        case .precomposition: .precomposition
        }
    }
}

/// 一份合成内部的不可变图层记录；时间均保留为父合成帧，不是微秒。
struct SourceLayer: Sendable {
    /// 当前合成内唯一的编码 ID，不直接作为公开实例身份。
    let id: UInt32
    /// 原始名称，允许为空或与其他层重复。
    let name: String
    /// 父变换源图层 ID；nil 表示直接使用所属合成坐标系。
    let parentID: UInt32?
    /// 父合成时间轴上的起始帧，可为负。
    let startFrame: Int64
    /// 可见区间的正帧数。
    let durationFrames: Int64
    /// 文件中的显示开关，不替代时间区间判定。
    let isActive: Bool
    /// 完整二维变换轨道，常量或关键帧均保留，不允许缺失。
    let transform: SourceTransformProperties
    /// 图层内容或跨合成引用。
    let content: SourceLayerContent
    /// 文件内图层标记，保留原始帧与备注；不参与画面求值，没有标记时为空。
    let markers: [SourceMarker]
    /// 文件中的层时间字段；不把它与ImageFillRule的素材采样轨道混用。
    let timing: SourceLayerTiming
    /// 图片层的素材适配规则；nil表示未编码，不能用缺省规则覆盖文件缩放表。
    let imageFillRule: SourceImageFillRule?

    /// 组合已读取的属性、内容和可选素材规则；时间字段与标记保持源元数据身份，不生成额外图层。
    init(id: UInt32, name: String, parentID: UInt32?, startFrame: Int64, durationFrames: Int64,
         isActive: Bool, transform: SourceTransformProperties, content: SourceLayerContent,
         markers: [SourceMarker] = [], timing: SourceLayerTiming = .identity,
         imageFillRule: SourceImageFillRule? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.startFrame = startFrame
        self.durationFrames = durationFrames
        self.isActive = isActive
        self.transform = transform
        self.content = content
        self.markers = markers
        self.timing = timing
        self.imageFillRule = imageFillRule
    }
}

/// 图片替换的源规则；Frame轨道在所属合成时间轴上，不是Layer的Float32时间元数据。
struct SourceImageFillRule: Sendable {
    /// 有规则时始终优先于文件表，未显式编码也使用aspectFit。
    let scaleMode: PAGScaleMode
    /// 完整原始帧号轨道；缺失或常量由准备层解释为默认线性素材时钟。
    let timeRemap: SourceProperty<Int64>
}

/// 图层自身的原始时间元数据；当前经典PAG源码不据此重映射内容帧，区别于图片素材时间。
struct SourceLayerTiming: Sendable {
    /// 未约分的有符号stretch分子，允许为零，不作为本库播放速度。
    let stretchNumerator: Int32
    /// 原始正分母；编码零在读取时拒绝，不保存无定义比例。
    let stretchDenominator: UInt32
    /// Float32来源的完整轨道；上游仅用其变化区间排除矢量静态缓存复用。
    let timeRemap: SourceProperty<Double>

    /// LayerAttributes未编码相应字段时使用的源码默认值；常量零不表示冻结内容。
    static let identity = SourceLayerTiming(stretchNumerator: 1, stretchDenominator: 1,
                                           timeRemap: SourceProperty(constant: 0))
}

/// 图层标记的只读元数据，不负责播放、事件派发或音频同步。
struct SourceMarker: Sendable {
    /// ReadTime得到的源帧起点，尚未换算成公开微秒。
    let startFrame: Int64
    /// ReadTime得到的源帧时长，字段缺省为0；不拿它定义层的可见区间。
    let durationFrames: Int64
    /// 上游verifyExtra要求非空的UTF-8备注。
    let comment: String
}

/// 不可变合成源；vector的layers为编码顺序，bitmap/video不创建人工图层。
struct SourceComposition: Sendable {
    /// 文档内唯一的编码 ID。
    let id: UInt32
    /// 合成的有限正逻辑尺寸。
    let size: PAGSize
    /// 合成的正帧数。
    let durationFrames: Int64
    /// 文件记录的有限正帧率。
    let frameRate: Double
    /// 背景元数据；不能据此把显示目标清成不透明颜色。
    let background: SceneColor
    /// 当前合成的源图层，仅存一次，不展开预合成。
    let layers: [SourceLayer]
    /// bitmap合成的内嵌序列；与video及非空layers互斥，nil表示没有bitmap内容。
    let bitmap: SourceBitmapComposition?
    /// PAG内嵌H.264序列；与bitmap及非空layers互斥，nil表示没有video内容。
    let video: SourceVideoComposition?

    /// 保存共同属性与一种内容，互斥性由SceneValidator校验；序列合成的直接子层集合为空。
    init(id: UInt32, size: PAGSize, durationFrames: Int64, frameRate: Double, background: SceneColor,
         layers: [SourceLayer], bitmap: SourceBitmapComposition? = nil, video: SourceVideoComposition? = nil) {
        self.id = id
        self.size = size
        self.durationFrames = durationFrames
        self.frameRate = frameRate
        self.background = background
        self.layers = layers
        self.bitmap = bitmap
        self.video = video
    }
}
