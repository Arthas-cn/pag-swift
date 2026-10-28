/// 解码后的基础图层内容；只保存源记录，不复制预合成的资源。
enum SourceLayerContent: Sendable {
    /// 不绘制像素，但仍能参与父变换链的控制层。
    case null
    /// 具有正尺寸的单色区域。
    case solid(size: PAGSize, color: SceneColor)
    /// 按文件顺序排列的静态形状操作。
    case shape([SourceShape])
    /// 文字样式与原始排版参数；可选动画器另存于SourceLayer。
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

/// 轨道遮罩的文件值；源拓扑保留原值，实际引用由邻层计划和局部Metal效果消费。
enum SourceTrackMatteType: UInt8, Sendable {
    /// 文件缺省值；这一层不请求前一编码层作为遮罩。
    case none = 0
    /// 使用相邻前一层的透明度遮住当前层。
    case alpha = 1
    /// 使用相邻前一层透明度的反值保留当前层。
    case alphaInverted = 2
    /// 使用相邻前一层的亮度作为当前层遮罩。
    case luma = 3
    /// 使用相邻前一层亮度的反值保留当前层。
    case lumaInverted = 4
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
    /// 原始遮罩模式；首个编码层即使非None也保留文件值，引用由合成拓扑决定。
    let trackMatte: SourceTrackMatteType
    /// 图层完整内容与此前背景的混合模式；不由子图元分别消费。
    let blendMode: SourceLayerBlendMode
    /// tag57真实绿通道直通子范围；只允许在Screen预合成完整内容后消费。
    let levelsGreenOnly: Bool
    /// tag63相邻帧运动模糊位；真正跳过与否由计划时的前后矩阵决定。
    let motionBlur: Bool
    /// 完整二维变换轨道，常量或关键帧均保留，不允许缺失。
    let transform: SourceTransformProperties
    /// 图层内容或跨合成引用。
    let content: SourceLayerContent
    /// 按LayerTag编码顺序保留的图层蒙版；空数组表示不安装蒙版裁剪。
    let masks: [SourceMask]
    /// tag69文字沿路径的源轨道；nil表示普通文字层，不从同名mask推断。
    let textPath: SourceTextPathOption?
    /// 按tag70编码顺序保留的文字动画器；空数组表示无逐字形效果。
    let textAnimators: [SourceTextAnimator]
    /// 按tag29/65编码顺序保留的静态下方投影；空数组仅表示没有投影。
    let dropShadows: [SourceDropShadow]
    /// tag85整层渐变叠加；nil表示未编码，不把样式摊成每个Shape的填充。
    let gradientOverlay: SourceGradientOverlay?
    /// 图像层的tag56平铺轨道；nil表示按普通图像直接采样。
    let motionTile: SourceMotionTile?
    /// 图像层的tag59凸出轨道；nil表示输入纹理没有空间扭曲。
    let bulge: SourceBulge?
    /// 图像层tag58的四角透视轨道；nil表示无四边形输出变形。
    let cornerPin: SourceCornerPin?
    /// tag61预合成完整内容的Glow轨道；nil表示无需两轴模糊与Merge。
    let glow: SourceGlow?
    /// tag60在Glow之后的Gaussian轨道；nil表示没有后续模糊阶段。
    let fastBlur: SourceFastBlur?
    /// 文件内图层标记，保留原始帧与备注；不参与画面求值，没有标记时为空。
    let markers: [SourceMarker]
    /// 文件中的层时间字段；不把它与ImageFillRule的素材采样轨道混用。
    let timing: SourceLayerTiming
    /// 图片层的素材适配规则；nil表示未编码，不能用缺省规则覆盖文件缩放表。
    let imageFillRule: SourceImageFillRule?

    /// 组合已读取的属性、遮罩模式、内容与可选素材规则；不在单层上猜测相邻引用。
    init(id: UInt32, name: String, parentID: UInt32?, startFrame: Int64, durationFrames: Int64,
         isActive: Bool, trackMatte: SourceTrackMatteType = .none,
         blendMode: SourceLayerBlendMode = .normal, levelsGreenOnly: Bool = false,
         motionBlur: Bool = false,
         transform: SourceTransformProperties, content: SourceLayerContent,
         masks: [SourceMask] = [], textPath: SourceTextPathOption? = nil,
         textAnimators: [SourceTextAnimator] = [], dropShadows: [SourceDropShadow] = [],
         gradientOverlay: SourceGradientOverlay? = nil,
         motionTile: SourceMotionTile? = nil, bulge: SourceBulge? = nil,
         cornerPin: SourceCornerPin? = nil, glow: SourceGlow? = nil,
         fastBlur: SourceFastBlur? = nil,
         markers: [SourceMarker] = [], timing: SourceLayerTiming = .identity,
         imageFillRule: SourceImageFillRule? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.startFrame = startFrame
        self.durationFrames = durationFrames
        self.isActive = isActive
        self.trackMatte = trackMatte
        self.blendMode = blendMode
        self.levelsGreenOnly = levelsGreenOnly
        self.motionBlur = motionBlur
        self.transform = transform
        self.content = content
        self.masks = masks
        self.textPath = textPath
        self.textAnimators = textAnimators
        self.dropShadows = dropShadows
        self.gradientOverlay = gradientOverlay
        self.motionTile = motionTile
        self.bulge = bulge
        self.cornerPin = cornerPin
        self.glow = glow
        self.fastBlur = fastBlur
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

/// 图层或合成标记的只读元数据，不负责播放、事件派发或音频同步。
struct SourceMarker: Sendable {
    /// ReadTime得到的源帧起点，尚未换算成公开微秒。
    let startFrame: Int64
    /// ReadTime得到的源帧时长，字段缺省为0；不拿它定义层的可见区间。
    let durationFrames: Int64
    /// UTF-8备注；Layer::verifyExtra要求图层非空，合成允许空串。
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

    /// 合成原始音频元数据；nil表示没有tag55，不参与画面时间或媒体采样。
    let audio: SourceAudio?
    /// 合成音频标记，允许空备注且不依赖audio存在；按编码顺序保存。
    let audioMarkers: [SourceMarker]

    /// 保存共同属性、音频元数据与一种画面内容；序列合成的直接子层集合为空。
    init(id: UInt32, size: PAGSize, durationFrames: Int64, frameRate: Double, background: SceneColor,
         layers: [SourceLayer], bitmap: SourceBitmapComposition? = nil, video: SourceVideoComposition? = nil,
         audio: SourceAudio? = nil, audioMarkers: [SourceMarker] = []) {
        self.id = id
        self.size = size
        self.durationFrames = durationFrames
        self.frameRate = frameRate
        self.background = background
        self.layers = layers
        self.bitmap = bitmap
        self.video = video
        self.audio = audio
        self.audioMarkers = audioMarkers
    }
}
