/// 某次根采样对应的显示计划；仅含 Sendable 几何与资源身份，不持有平台绘制对象。
struct FramePlan: Sendable {
    /// 已接受请求及量化帧时刻；计划本身不意味着 GPU 已显示。
    let time: RootSampleTime
    /// 最终 drawable 像素边界；与根合成自身的变换后裁剪共同生效。
    let targetBounds: DisplayRect
    /// 按实际覆盖顺序排列，组开始与结束严格配对。
    let commands: [FrameCommand]
}

/// 逻辑矩形及其显示映射；保留旋转后的真实形状，不用轴对齐包围盒替代裁剪。
struct FrameClip: Sendable, Equatable {
    /// 以局部原点为左上角的正尺寸。
    let size: PAGSize
    /// 逻辑坐标到目标像素的有限矩阵。
    let matrix: SceneAffine
}

/// 图层蒙版的不可变来源；普通clip与羽化效果在Metal阶段采用不同的覆盖位置。
enum FrameMaskSource: Sendable {
    /// 一条路径仍直接复用原SourcePath对象身份。
    case path(SourcePath)
    /// 多条路径按源顺序构成布尔结果，不以首路径冒充完整键。
    case expression(SampledMaskExpression)
    /// 羽化分支保留全部源项和各项alpha；必须先合成内容再应用总体蒙版。
    case feather(SampledFeatherMask)
}

/// 一层蒙版的已采样作用域；只保留不可变来源和最终显示矩阵，不持有GPU资源。
struct FrameMask: Sendable {
    /// 产生此蒙版的实际图层实例，不能与同源其他实例混淆。
    let layerID: PAGLayerID
    /// 经所属合成帧采样的普通路径或羽化列表来源。
    let source: FrameMaskSource
    /// 普通clip的最终补集位；羽化各项补集位在source内，此字段固定false。
    let isInverted: Bool
    /// 蒙版局部坐标到显示像素的完整层矩阵，含控制父链与预合成祖先。
    let matrix: SceneAffine

    /// 保存图层实例与不可变来源；GPU阶段按分支准备网格或局部效果附件。
    init(layerID: PAGLayerID, source: FrameMaskSource, isInverted: Bool, matrix: SceneAffine) {
        self.layerID = layerID
        self.source = source
        self.isInverted = isInverted
        self.matrix = matrix
    }
}

/// 一次邻层轨道遮罩的来源与拥有者作用域；两段命令必须分别准备，不能顺序画到根目标。
struct FrameTrackMatte: Sendable {
    /// 被遮罩的实际实例；同一源定义可在不同预合成实例中独立出现。
    let ownerID: PAGLayerID
    /// 当前模式决定alpha/luma取样及反向规则，不取源层自身属性。
    let mode: SourceTrackMatteType
    /// 只有源图层实际要求非默认图层混合时，遮罩完成后才应用；普通遮罩为Normal。
    let ownerBlendMode: SourceLayerBlendMode
    /// 非默认图层混合的拥有者整体alpha，必须在遮罩结果上只乘一次。
    let ownerOpacity: Double

    /// 默认遮罩仍沿用原普通SrcOver；显式混合由真实拥有者图层提供。
    init(ownerID: PAGLayerID, mode: SourceTrackMatteType,
         ownerBlendMode: SourceLayerBlendMode = .normal, ownerOpacity: Double = 1) {
        self.ownerID = ownerID
        self.mode = mode
        self.ownerBlendMode = ownerBlendMode
        self.ownerOpacity = ownerOpacity
    }
}

/// 一层静态下方投影的来源与整体透明度；内容必须先独立组合，再按样式顺序绘回。
struct FrameDropShadow: Sendable {
    /// 当前展开图层的实例身份，不能用源定义身份合并不同变换。
    let layerID: PAGLayerID
    /// 图层到最终显示像素的矩阵，用于把源像素尺度映入投影滤镜。
    let matrix: SceneAffine
    /// 当前图层自身二维矩阵；上游投影先除去其轴尺度再交给内容滤镜。
    let layerMatrix: SceneAffine
    /// 按tag顺序保留的非空投影列表；未可见项由效果准备时判断。
    let styles: [SourceDropShadow]
    /// 图层自身alpha，在投影与原内容组合后只消费一次。
    let opacity: Double
}

/// 整层Shape先合成后覆盖的Angle渐变；只承载已证实的白黑单样式子范围。
struct FrameGradientOverlay: Sendable {
    /// 实际图层实例，供局部样式工作与源Shape边界对应。
    let layerID: PAGLayerID
    /// 当前所属合成帧采样的角度，按上游360-angle进入样式矩阵。
    let angle: Double
    /// 整层变换透明度，在渐变与原内容混合完成后只应用一次。
    let opacity: Double
}

/// Shape整层在自身坐标执行FastBlur，随后才与已有颜色作HardLight。
struct FrameShapeBlurBlend: Sendable {
    /// 实际图层实例，防止局部命令范围串到相邻Shape。
    let layerID: PAGLayerID
    /// Shape局部坐标到最终显示像素，模糊前不烘入旋转或非等比缩放。
    let matrix: SceneAffine
    /// 当前帧已采样的tag60参数；零值也保持整层混合边界。
    let blur: SampledFastBlur
    /// 未遮罩时由当前结果draw消费；被轨道遮罩拥有时固定1，整体alpha移到遮罩后。
    let opacity: Double
    /// Track Matte拥有者先Normal写其内容表面；未遮罩图层直接以HardLight写背景。
    let blendMode: SourceLayerBlendMode

    /// 明确区分内部滤镜结果与外层图层混合，避免轨道遮罩提前读取错误背景。
    init(layerID: PAGLayerID, matrix: SceneAffine, blur: SampledFastBlur,
         opacity: Double, blendMode: SourceLayerBlendMode = .hardLight) {
        self.layerID = layerID
        self.matrix = matrix
        self.blur = blur
        self.opacity = opacity
        self.blendMode = blendMode
    }
}

/// Text层Bulge的完整合成输入引用；父合成尺寸定义滤镜域，字形只借紧致内容附件。
struct FrameTextBulge: Sendable {
    /// 展开实例身份，不能把同源不同图层的局部内容混用。
    let layerID: PAGLayerID
    /// 所属合成的源帧，局部批次保持与当前文字样本一致。
    let frame: Int64
    /// 上游TextLayer.getBounds采用的所属合成尺寸。
    let compositionSize: PAGSize
    /// 所属合成坐标到最终显示像素的矩阵，不包含Text自身层矩阵。
    let compositionMatrix: SceneAffine
    /// 当前帧以所属合成完整尺寸归一的Bulge值。
    let bulge: FrameBulge
    /// 原图层整体透明度，必须在全部字形合成和效果之后消费一次。
    let opacity: Double
    /// 可选文字背景先于全部轮次绘制。
    let background: FrameShape?
    /// 字形填充/描边轮次保持原上游顺序；空数组只允许存在背景。
    let passes: [FrameText]
}

/// 合成包含边界；裁剪始终作用于子内容，alpha按实际绘制粒度消费。
struct FrameGroup: Sendable {
    /// 来源预合成实例；根合成没有人工图层身份，因此为 nil。
    let layerID: PAGLayerID?
    /// 生产计划中的源合成定义索引；手写测试计划可为nil，Vector标记必须与之匹配。
    let definitionIndex: Int?
    /// 此次进入合成后选定的合法内容帧，便于媒体准备与数值验证。
    let frame: Int64
    /// 当前合成的逻辑边界及其到显示目标的映射。
    let clip: FrameClip
    /// 此合成边界的不透明度，范围 0...1；根始终为 1。
    let opacity: Double
    /// 图层完整内容的混合方式；根和普通预合成始终Normal。
    let blendMode: SourceLayerBlendMode
    /// tag57只在整层合成后归零红蓝；普通组为false。
    let levelsGreenOnly: Bool
    /// 预合成整层内容之后的平铺效果；普通组合为nil。
    let motionTile: FrameMotionTile?
    /// tag63当前帧相对上一内容帧的矩阵差；相等已在计划阶段跳过。
    let motionBlur: MotionBlurSampling?
    /// 整组内容合成后才使用的tag61单效果数值；nil表示没有Glow。
    let glow: SampledGlow?
    /// tag59在前置MotionTile与Glow之后的当前帧值；零height跳过时为nil。
    let tileGlowBulge: SampledBulge?
    /// Glow后顺序执行的tag60数值；零模糊在本帧跳过GPU阶段。
    let fastBlur: SampledFastBlur?
    /// 无快照时逐次绘制继承alpha，只有明确已组合内容才能选择composite。
    let application: FrameOpacityApplication

    /// 保留合成裁剪与采样身份；默认按当前无快照生产路径逐draw消费alpha。
    init(layerID: PAGLayerID?, frame: Int64, clip: FrameClip, opacity: Double,
         application: FrameOpacityApplication = .perDraw, definitionIndex: Int? = nil,
         blendMode: SourceLayerBlendMode = .normal, levelsGreenOnly: Bool = false,
         motionTile: FrameMotionTile? = nil, motionBlur: MotionBlurSampling? = nil,
         glow: SampledGlow? = nil, fastBlur: SampledFastBlur? = nil,
         tileGlowBulge: SampledBulge? = nil) {
        self.layerID = layerID
        self.definitionIndex = definitionIndex
        self.frame = frame
        self.clip = clip
        self.opacity = opacity
        self.blendMode = blendMode
        self.levelsGreenOnly = levelsGreenOnly
        self.motionTile = motionTile
        self.motionBlur = motionBlur
        self.glow = glow
        self.fastBlur = fastBlur
        self.tileGlowBulge = tileGlowBulge
        self.application = application
    }
}

/// 静态Vector定义的可选局部快照边界；不持有子内容，失败后仍逐条执行原计划。
struct FrameVectorPicture: Sendable {
    /// 完整源文件身份，避免不同文件的同下标定义共用纹理。
    let document: DocumentIdentity
    /// 已验证的源合成定义索引，不能借某个子层索引充当Vector身份。
    let definitionIndex: Int
    /// 当前展开实例；根定义没有人工层身份，因此为nil。
    let layerID: PAGLayerID?
    /// 有逐实例visibility编辑时隔离内容缓存；无此编辑时为nil，允许同定义跨实例共享。
    let cacheVariant: PAGLayerID?
    /// 定义局部坐标到最终显示像素的完整仿射变换。
    let matrix: SceneAffine
}

/// 单个纯色矩形的已求值命令；几何以局部原点为左上角。
struct FrameSolid: Sendable {
    /// 来源图层的实例身份，用于诊断与编辑版本对应。
    let layerID: PAGLayerID
    /// 矩形的有限正逻辑尺寸。
    let size: PAGSize
    /// 未预乘的 RGB 源色；统一色彩数值域与预乘由共同渲染器处理。
    let color: SceneColor
    /// 局部矩形到显示像素的矩阵，已包含控制父链和预合成变换。
    let matrix: SceneAffine
    /// 此图层自身的不透明度，不预乘所属组 opacity。
    let opacity: Double
}

/// 单个图像输入的已求值命令；图像像素只作为输入资源，不是最终帧读回。
struct FrameImage: Sendable {
    /// 来源图层的实例身份，同一原始资源可以有多份实例；根 bitmap 合成没有人工层，为 nil。
    let layerID: PAGLayerID?
    /// PreparedFrame.images 中的资源内容身份。
    let resourceID: DocumentIdentity
    /// 已应用 EXIF 的输入像素尺寸，纹理坐标覆盖整个输入。
    let pixelSize: PAGSize
    /// 输入像素坐标到显示像素的映射，已包含原图裁边或替换适配。
    let matrix: SceneAffine
    /// 仅替换素材附加原始逻辑框裁剪；原图为 nil，仍受所属合成组裁剪。
    let clip: FrameClip?
    /// 此图层自身不透明度，所属组透明度保持在 beginGroup 中。
    let opacity: Double
    /// 原图按图层局部时间，替换按根实例ImageFillRule映射；可含缓动越界值，静图不依赖此采样时间。
    let contentTime: PAGTime
    /// tag56效果的输入归一化中心与逐帧参数；nil走普通图片采样。
    let motionTile: FrameMotionTile?
    /// 图像平铺之后相对上一内容帧的矩阵差；静态相等或未启用时为nil。
    let motionBlur: MotionBlurSampling?
    /// tag59图像凸出效果的归一化几何；nil表示无可见凸出。
    let bulge: FrameBulge?
    /// tag58四角逆投影；nil表示没有图像透视输出。
    let cornerPin: FrameCornerPin?

    /// 保留图像输入身份与可选效果，默认调用仍不改变普通图片语义。
    init(layerID: PAGLayerID?, resourceID: DocumentIdentity, pixelSize: PAGSize,
         matrix: SceneAffine, clip: FrameClip?, opacity: Double, contentTime: PAGTime,
         motionTile: FrameMotionTile? = nil, motionBlur: MotionBlurSampling? = nil,
         bulge: FrameBulge? = nil,
         cornerPin: FrameCornerPin? = nil) {
        self.layerID = layerID
        self.resourceID = resourceID
        self.pixelSize = pixelSize
        self.matrix = matrix
        self.clip = clip
        self.opacity = opacity
        self.contentTime = contentTime
        self.motionTile = motionTile
        self.motionBlur = motionBlur
        self.bulge = bulge
        self.cornerPin = cornerPin
    }
}

/// 当前帧图像凸出滤镜的输入与输出矩形，数值均相对于原图像素单位坐标。
struct FrameBulge: Sendable {
    /// 输入内容归一化中心，可位于输入矩形之外。
    let center: ScenePoint
    /// 水平作用半径相对于输入内容宽度。
    let radiusX: Double
    /// 垂直作用半径相对于输入内容高度。
    let radiusY: Double
    /// 上游着色器的凸出位移系数，可正可负。
    let height: Double
    /// true在采样前钳边；false超出输入矩形的像素透明。
    let pinning: Bool
    /// 滤镜输出矩形的左上角，pinning时固定为零。
    let outputOrigin: ScenePoint
    /// 滤镜输出矩形的正尺寸，pinning时固定为单位尺寸。
    let outputSize: PAGSize

    /// 将局部值逆映到效果输入AABB；若前一效果是CornerPin，须以它的输出归一化。
    init(_ sampled: SampledBulge, placement: SceneAffine, pixelSize: PAGSize,
         cornerPin: FrameCornerPin? = nil) throws {
        let inverse = try placement.inverted()
        let origin = try inverse.applying(to: sampled.center)
        let right = try inverse.applying(to: ScenePoint(x: sampled.center.x + sampled.horizontalRadius,
            y: sampled.center.y))
        let bottom = try inverse.applying(to: ScenePoint(x: sampled.center.x,
            y: sampled.center.y + sampled.verticalRadius))
        let inputOrigin = cornerPin?.outputOrigin ?? .zero
        let inputSize = cornerPin?.outputSize ?? pixelSize
        center = ScenePoint(x: (origin.x - inputOrigin.x) / inputSize.width,
            y: (origin.y - inputOrigin.y) / inputSize.height)
        radiusX = abs(right.x - origin.x) / inputSize.width
        radiusY = abs(bottom.y - origin.y) / inputSize.height
        height = sampled.height
        pinning = sampled.pinning
        guard center.x.isFinite, center.y.isFinite, radiusX.isFinite, radiusY.isFinite,
              radiusX > 0, radiusY > 0 else {
            throw PAGError.unsupportedFeature("bulgeDimensions")
        }
        var left = 0.0, top = 0.0, rightEdge = 1.0, bottomEdge = 1.0
        if !pinning {
            let unitX = abs(inverse.a) / inputSize.width
            let unitY = abs(inverse.d) / inputSize.height
            let nearestX = min(max(center.x, 0), 1)
            let nearestY = min(max(center.y, 0), 1)
            let dx = (nearestX - center.x) / (radiusX + unitX)
            let dy = (nearestY - center.y) / (radiusY + unitY)
            // 上游椭圆半径额外加一个局部单位，以免仅相切的交集被空路径漏掉。
            if dx * dx + dy * dy <= 1 {
                if center.x > left && center.x - radiusX < left { left = center.x - radiusX }
                if center.x < rightEdge && center.x + radiusX > rightEdge { rightEdge = center.x + radiusX }
                if center.y > top && center.y - radiusY < top { top = center.y - radiusY }
                if center.y < bottomEdge && center.y + radiusY > bottomEdge { bottomEdge = center.y + radiusY }
            }
        }
        outputOrigin = ScenePoint(x: left, y: top)
        outputSize = try PAGSize(width: rightEdge - left, height: bottomEdge - top)
    }
}

/// 图像层MotionTile的当前帧效果；中心已由ImagePlacement逆映到实际输入纹理单位坐标。
struct FrameMotionTile: Sendable {
    /// 相对于图像输入宽高的平铺中心，可位于纹理边界之外。
    let center: ScenePoint
    /// 每块横向尺寸相对于输入宽度的百分数。
    let tileWidth: Double
    /// 每块纵向尺寸相对于输入高度的百分数。
    let tileHeight: Double
    /// 输出横向尺寸相对于输入宽度的百分数。
    let outputWidth: Double
    /// 输出纵向尺寸相对于输入高度的百分数。
    let outputHeight: Double
    /// 奇数块是否将对应采样轴镜像。
    let mirrorEdges: Bool
    /// 正度数才执行交错位移。
    let phase: Double
    /// 交错位移是否沿奇数行横向执行。
    let horizontalPhaseShift: Bool

    /// 预合成效果以完整子合成尺寸归一中心；局部GPU纹理的紧致尺寸不改变此域。
    init(_ sampled: SampledMotionTile, compositionSize: PAGSize) throws {
        let normalized = ScenePoint(x: sampled.center.x / compositionSize.width,
                                    y: sampled.center.y / compositionSize.height)
        guard normalized.x.isFinite, normalized.y.isFinite else {
            throw PAGError.unsupportedFeature("motionTileCenter")
        }
        center = normalized
        tileWidth = sampled.tileWidth
        tileHeight = sampled.tileHeight
        outputWidth = sampled.outputWidth
        outputHeight = sampled.outputHeight
        mirrorEdges = sampled.mirrorEdges
        phase = sampled.phase
        horizontalPhaseShift = sampled.horizontalPhaseShift
    }

    /// 把源层效果中心通过图像布局逆变换映回像素归一化域，失败不发布半份计划。
    init(_ sampled: SampledMotionTile, placement: SceneAffine, pixelSize: PAGSize) throws {
        let pixel = try placement.inverted().applying(to: sampled.center)
        let normalized = ScenePoint(x: pixel.x / pixelSize.width, y: pixel.y / pixelSize.height)
        guard normalized.x.isFinite, normalized.y.isFinite else {
            throw PAGError.unsupportedFeature("motionTileCenter")
        }
        center = normalized
        tileWidth = sampled.tileWidth
        tileHeight = sampled.tileHeight
        outputWidth = sampled.outputWidth
        outputHeight = sampled.outputHeight
        mirrorEdges = sampled.mirrorEdges
        phase = sampled.phase
        horizontalPhaseShift = sampled.horizontalPhaseShift
    }
}

/// 内嵌或外部视频在当前时刻的只读绘制命令；纯值计划不持有CoreVideo或Metal对象。
struct FrameVideo: Sendable {
    /// 来源预合成实例；根video合成没有人工图层身份，为nil。
    let layerID: PAGLayerID?
    /// PreparedFrame.videos中的序列/实际PTS身份，不能用请求帧号替代空洞后的PTS。
    let resourceID: VideoFrameID
    /// 可见颜色区域的像素尺寸，不包括PAG alpha区域。
    let pixelSize: PAGSize
    /// 可见像素到最终显示像素的完整矩阵，含序列尺寸到合成尺寸的缩放。
    let matrix: SceneAffine
    /// 当前图元透明度；合成整体alpha仍留在beginGroup中。
    let opacity: Double
    /// 外部替换素材按原图层逻辑边界裁剪；内嵌视频无需附加裁剪。
    let clip: FrameClip?

    /// 保留既有内嵌视频参数，并为外部替换额外接受局部图层裁剪。
    init(layerID: PAGLayerID?, resourceID: VideoFrameID, pixelSize: PAGSize,
         matrix: SceneAffine, opacity: Double, clip: FrameClip? = nil) {
        self.layerID = layerID
        self.resourceID = resourceID
        self.pixelSize = pixelSize
        self.matrix = matrix
        self.opacity = opacity
        self.clip = clip
    }
}

/// 无额外裁剪的透明度如何被消费；普通Shape组与已组合内容不能混为一种附件语义。
enum FrameOpacityApplication: Sendable {
    /// 继承到每次实际绘制，普通Shape内部组不为自身创建颜色附件。
    case perDraw
    /// 作用于明确已组合的内容一次；候选资格本身不能选择此分支。
    case composite
}

/// 不带额外裁剪的透明度边界；application区分继承和内容组合。
struct FrameOpacityGroup: Sendable {
    /// 对应的图层实例，多个内部组可以属于同一层。
    let layerID: PAGLayerID
    /// 此作用域的不透明度，范围0...1；消费位置由application决定。
    let opacity: Double
    /// 无实际快照的Shape/Text图层及普通Shape内部组均为perDraw。
    let application: FrameOpacityApplication

    /// 保存透明度及明确的消费方式；默认按无快照绘制展开。
    init(layerID: PAGLayerID, opacity: Double, application: FrameOpacityApplication = .perDraw) {
        self.layerID = layerID
        self.opacity = opacity
        self.application = application
    }
}

/// 一次 nonzero 复合路径填充，资源中的全部轮廓共同决定覆盖区域。
struct FrameShape: Sendable {
    /// 当前图层实例的身份，几何仍按源层共享。
    let layerID: PAGLayerID
    /// PreparedFrame.shapes 中已准备的解析几何身份。
    let geometryID: ShapeGeometryID
    /// 形状图层坐标到显示像素的映射；内部组矩阵已经保留在几何轮廓里。
    let matrix: SceneAffine
    /// 当前填充的不可变材料，渐变组坐标保留在材料内部。
    let material: ShapeMaterial
    /// 当前 fill 自身的 opacity，不包含形状组、图层和预合成 alpha。
    let opacity: Double
}

/// 图层内容的可选Picture边界；内部原命令始终保留供DisableCache或资源miss逐draw展开。
struct FramePicture: Sendable {
    /// 完整文档内容身份，防止不同文件的同下标源层混用纹理。
    let document: DocumentIdentity
    /// 静态Shape或Text源层；同源多实例可以共享相同内容纹理。
    let source: SourceLayerReference
    /// 内容局部坐标到显示像素的矩阵，实例位置不进入内容键。
    let matrix: SceneAffine
    /// 内容种类；Text还携带本次编辑资源与实例身份，不能仅以源层识别字形。
    let content: FramePictureContent

    /// 建立内容边界；默认Shape保持既有调用，Text必须显式给出准备资源和实例。
    init(document: DocumentIdentity, source: SourceLayerReference, matrix: SceneAffine,
         content: FramePictureContent = .shape) {
        self.document = document
        self.source = source
        self.matrix = matrix
        self.content = content
    }
}

/// 局部Picture的实际内容身份；Text编辑代数和当前实例只用于严格范围校验。
enum FramePictureContent: Sendable {
    /// 源Shape的静态几何paint及内部Shape组。
    case shape
    /// 当前准备的完整文本资源与这次展开的图层实例。
    case text(resourceID: TextResourceID, layerID: PAGLayerID)
}

/// 一个完整文本 fill 或 stroke pass；几何和层内位置已经在后台准备。
struct FrameText: Sendable {
    /// 来源图层实例，多个实例仍共享同一份文本资源。
    let layerID: PAGLayerID
    /// PreparedFrame.texts 中的稳定准备代数。
    let resourceID: TextResourceID
    /// PreparedTextLayer.passes 中合法的绘制轮次索引。
    let passIndex: Int
    /// 文字图层坐标到目标像素的映射，字形局部矩阵在资源中独立保存。
    let matrix: SceneAffine
}

/// 严格顺序的显示指令；每种资源的完整语义在准备阶段通过后才能进入。
enum FrameCommand: Sendable {
    /// 进入带真实矩形裁剪和整体 alpha 的合成组。
    case beginGroup(FrameGroup)
    /// 结束最近一次 beginGroup，恢复之前的裁剪与组状态。
    case endGroup
    /// 在当前图层矩阵下进入普通路径裁剪，每次实际draw分别消费覆盖率。
    case beginMask(FrameMask)
    /// 结束最近的图层蒙版，预合成子树必须在此之前完整退出。
    case endMask
    /// 开始轨道遮罩；随后先发源图形，再发拥有者图形，Metal不能将任一段直接泄露到根pass。
    case beginTrackMatte(FrameTrackMatte)
    /// 结束独立源图形并开始拥有者；空源也必须保留此边界以按正反向分流。
    case endTrackMatteSource
    /// 结束拥有者并恢复此前兄弟的绘制作用域。
    case endTrackMatte
    /// 开始图层投影的原始内容边界，内含该层蒙版但不含图层自身整体alpha。
    case beginDropShadow(FrameDropShadow)
    /// 结束当前层原始内容，并在同一覆盖位置绘制下方投影与源图。
    case endDropShadow
    /// 开始整层GradientOverlay的原始Shape内容，样式不逐图元施加。
    case beginGradientOverlay(FrameGradientOverlay)
    /// 结束原始Shape内容并把局部样式结果绘回当前显示作用域。
    case endGradientOverlay
    /// 开始Shape完整内容；局部FastBlur必须先于最终HardLight。
    case beginShapeBlurBlend(FrameShapeBlurBlend)
    /// 结束Shape内容并以一次图层混合写当前显示附件。
    case endShapeBlurBlend
    /// 直接绘制已求值的纯色矩形。
    case solid(FrameSolid)
    /// 按内容身份引用不可变图像输入，包括当前时刻已重建的 bitmap 素材帧。
    case image(FrameImage)
    /// 直接采样已硬解的视频两平面，不能先转换为整帧RGBA纹理。
    case video(FrameVideo)
    /// 进入不附加裁剪的透明度作用域，消费方式由关联值指定。
    case beginOpacityGroup(FrameOpacityGroup)
    /// 结束最近一次 beginOpacityGroup，不退出所属合成的矩形裁剪。
    case endOpacityGroup
    /// 对一个包含全部轮廓的几何资源进行 nonzero 填充。
    case shape(FrameShape)
    /// 开始可选Shape或Text内容快照；只有真实纹理成功时才替换范围内原命令。
    case beginPicture(FramePicture)
    /// 结束最近一次Picture范围，未命中时保留范围内逐draw结果。
    case endPicture
    /// 开始可选Vector定义快照；定义clip在范围内，实例外部alpha在范围外。
    case beginVectorPicture(FrameVectorPicture)
    /// 结束最近一次Vector范围；资源miss时继续原始子命令及其各自Picture资格。
    case endVectorPicture
    /// 完成一轮文字路径绘制后才执行下一轮，不逐字交替填充与描边。
    case text(FrameText)
    /// 把文字完整内容先组合到紧致局部附件，再以父合成尺寸在根drawable执行Bulge。
    case textBulge(FrameTextBulge)
}

/// 后台求值结果与其资源保活表；失败或取消时整个值都不发布。
struct PreparedFrame: Sendable {
    /// 不含系统对象或像素内容的显示计划。
    let plan: FramePlan
    /// 按完整内容身份去重的不可变输入，COW 共享像素，不在求值中复制或上传。
    let images: [DocumentIdentity: PAGImage]
    /// 本次计划引用的共享解析几何；准备期之后不复制轮廓或逐帧重新生成路径。
    let shapes: [ShapeGeometryID: ShapeGeometry]
    /// 本次计划引用的不可变文本资源；多帧共享路径和位置，没有系统字体对象。
    let texts: [TextResourceID: PreparedTextLayer]
    /// 经过局部同步桥保活的视频输入；只允许RenderOwner消费一次，不把裸帧放入FramePlan。
    let videos: [VideoFrameID: VideoFrameTransfer]
    /// 实际选中的占位实例；仅在有效GPU完成后由播放许可建立辅助时间起点。
    let placeholderIDs: [PAGLayerID]
    /// 本次正在播放且确实绘制了滚动文字的实例；有效GPU完成后才建立滚动起点。
    let marqueeIDs: [PAGLayerID]

    /// 组合完整计划与按身份去重的输入；不含视频的计划不分配媒体槽。
    init(plan: FramePlan, images: [DocumentIdentity: PAGImage], shapes: [ShapeGeometryID: ShapeGeometry],
         texts: [TextResourceID: PreparedTextLayer], videos: [VideoFrameID: VideoFrameTransfer] = [:],
         placeholderIDs: [PAGLayerID] = [], marqueeIDs: [PAGLayerID] = []) {
        self.plan = plan
        self.images = images
        self.shapes = shapes
        self.texts = texts
        self.videos = videos
        self.placeholderIDs = placeholderIDs
        self.marqueeIDs = marqueeIDs
    }
}
