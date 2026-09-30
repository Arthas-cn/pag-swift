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

/// 合成包含边界；opacity 作用于子内容的整体，区别于控制父链的矩阵继承。
struct FrameGroup: Sendable {
    /// 来源预合成实例；根合成没有人工图层身份，因此为 nil。
    let layerID: PAGLayerID?
    /// 此次进入合成后选定的合法内容帧，便于媒体准备与数值验证。
    let frame: Int64
    /// 当前合成的逻辑边界及其到显示目标的映射。
    let clip: FrameClip
    /// 此合成整体的不透明度，范围 0...1；根始终为 1。
    let opacity: Double
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
}

/// 内嵌视频在当前时刻的只读绘制命令；纯值计划不持有CoreVideo或Metal对象。
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
}

/// 不带额外裁剪的整体透明度边界，用于形状/文本层和 shape group。
struct FrameOpacityGroup: Sendable {
    /// 对应的图层实例，多个内部组可以属于同一层。
    let layerID: PAGLayerID
    /// 此组的整体不透明度，不应预乘到每个内部 fill，范围 0...1。
    let opacity: Double
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
    /// 直接绘制已求值的纯色矩形。
    case solid(FrameSolid)
    /// 按内容身份引用不可变图像输入，包括当前时刻已重建的 bitmap 素材帧。
    case image(FrameImage)
    /// 直接采样已硬解的视频两平面，不能先转换为整帧RGBA纹理。
    case video(FrameVideo)
    /// 进入不附加裁剪的整体透明度组，通常只为 alpha 不等于 1 的内容生成。
    case beginOpacityGroup(FrameOpacityGroup)
    /// 结束最近一次 beginOpacityGroup，不退出所属合成的矩形裁剪。
    case endOpacityGroup
    /// 对一个包含全部轮廓的几何资源进行 nonzero 填充。
    case shape(FrameShape)
    /// 完成一轮文字路径绘制后才执行下一轮，不逐字交替填充与描边。
    case text(FrameText)
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

    /// 组合完整计划与按身份去重的输入；不含视频的计划不分配媒体槽。
    init(plan: FramePlan, images: [DocumentIdentity: PAGImage], shapes: [ShapeGeometryID: ShapeGeometry],
         texts: [TextResourceID: PreparedTextLayer], videos: [VideoFrameID: VideoFrameTransfer] = [:]) {
        self.plan = plan
        self.images = images
        self.shapes = shapes
        self.texts = texts
        self.videos = videos
    }
}
