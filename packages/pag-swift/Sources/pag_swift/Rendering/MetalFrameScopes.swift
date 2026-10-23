import Metal

/// 两类组只能由自身的end关闭，避免损坏内部计划被悄悄接受。
enum MetalGroupKind {
    /// 附带合成逻辑边界裁剪的预合成/根组。
    case composition
    /// 没有新裁剪的透明度作用域，按application选择继承或内容组合。
    case opacity
}

/// 可选Shape或Text内容区间的起点；回退保留已生成的原绘制数组。
struct MetalPictureScope {
    /// 只包含源内容与当前实例变换的纯值标记。
    let picture: FramePicture
    /// beginPicture在原FramePlan中的下标，局部pass只消费其后续内部命令。
    let commandIndex: Int
    /// 首个原始绘制的下标，成功快照才替换此后的绘制。
    let drawIndex: Int
    /// 进入时真实祖先裁剪/alpha尚有可见范围。
    let wasVisible: Bool
}

/// 退出组时需要恢复的值，不包含系统对象或另一套播放器状态。
struct MetalGroupScope {
    /// 当前组的匹配种类。
    let kind: MetalGroupKind
    /// 进入之前的裁剪快照，Swift数组按COW共享。
    let previous: MetalClipValues
    /// 进入之前的仅可见性裁剪链；nil表示没有延迟coverage的祖先组。
    let previousDeferred: MetalClipValues?
    /// 父作用域的保守分配范围，nil表示父组已不可见。
    let previousLimit: RenderBounds?
    /// 进入组之前外层mask是否已因祖先真实颜色组合而延迟。
    let previousMaskDeferred: Bool
    /// 只在组结果应用的祖先与自身裁剪。
    let compositeClips: MetalClipValues
    /// 经过范围验证的0...1 alpha，具体消费位置由application决定。
    let opacity: Double
    /// perDraw在退出时原位乘当前子draw，composite在必要时创建独立结果。
    let application: FrameOpacityApplication
    /// Screen要求子图元先组合为一张局部结果，退出时才与背景混合。
    let blendMode: SourceLayerBlendMode
    /// 整层内容施加绿通道Levels后再Screen；内部子draw不能继承此标记。
    let levelsGreenOnly: Bool
    /// 预合成的完整内容平铺参数；nil表示普通组结果。
    let motionTile: FrameMotionTile?
    /// tag63当前相对上一内容帧的非零矩阵差，仅在完整效果后应用。
    let motionBlur: MotionBlurSampling?
    /// 整组内容合成后执行的唯一Glow；子图元不继承它。
    let glow: SampledGlow?
    /// MotionTile→Glow之后才执行的预合成Bulge，当前帧不可见时为nil。
    let tileGlowBulge: SampledBulge?
    /// Glow后执行的Gaussian参数；nil或零帧不会创建额外附件。
    let fastBlur: SampledFastBlur?
    /// 平铺输入的完整合成域；局部附件只负责保存实际内容像素。
    let compositionClip: FrameClip?
    /// 子内容在当前绘制数组中的起点。
    let start: Int
}

/// 尚未确定当前pass原点的绘制，在附件范围确定后一次生成Metal常量。
struct MetalPendingDraw {
    /// 已上传且保持不变的顶点。
    let mesh: MetalMesh
    /// 静图或子组结果，nil表示纯色。
    let texture: (any MTLTexture)?
    /// 业务槽位静态 alpha，不占用原文件普通路径遮罩的两层预算。
    let slotMask: MetalSlotMaskInput?
    /// 效果最终mask/邻层源表面；仅由已组合内容纹理携带并在片元只乘一次。
    let featherMaskTexture: (any MTLTexture)?
    /// 两平面视频及其CV包装；与texture互斥，组透明度折叠时仍保留整个输入。
    let video: MetalVideoInput?
    /// 与图片/视频互斥的材料，真实非空pass确定后才检查映射和解析可用性。
    let gradient: PreparedGradient?
    /// 网格局部坐标到最终显示像素的Double变换。
    let matrix: SceneAffine
    /// 按实际GPU系数固定的正逆变换；分配范围和最终片元查询共用，不在各pass重复计算。
    let transform: MetalDrawTransform
    /// 预乘颜色或图片四通道alpha；组退出时可折入继承alpha，编码后不再修改。
    var color: SIMD4<Float>
    /// 本图元实际需要执行的真实裁剪。
    let clips: MetalClipValues
    /// 每条实际绘制的普通路径覆盖；局部组合会决定继承到子draw还是结果draw。
    let mask: MetalMaskInput?
    /// 用于局部附件分配的可见保守范围。
    let bounds: RenderBounds
    /// 非nil时第二纹理按轨道遮罩模式读取，而非羽化单通道alpha。
    let trackMatteMode: SourceTrackMatteType?
    /// true时只取局部内容的alpha给投影颜色着色，不能乘源内容RGB。
    let isShadow: Bool
    /// 图像输入的平铺采样常量；nil保持原本的纹理线性采样。
    let motionTile: MetalMotionTileUniforms?
    /// 图像凸出效果仅绑定同一输入纹理的直接取样常量。
    let bulge: MetalBulgeUniforms?
    /// 四角透视效果在根pass反求前一效果输入单位坐标。
    let cornerPin: MetalCornerPinUniforms?
    /// Text Bulge的父合成输入到紧致局部附件UV的映射；其它材料无此值。
    let textBulgeMap: MetalTextBulgeMap?
    /// 外层普通路径只在图像双路径专用片元中消费；nil表示没有第二层路径。
    let parentMask: MetalMaskInput?
    /// 仅完整Screen组的最终结果为true，子图元仍以普通SrcOver绘制。
    let screenBlend: Bool
    /// Shape整层模糊结果需在片元读取当前颜色附件，以TGFX公式只混合一次。
    let hardLightBlend: Bool
    /// 仅tag57已证实的静态参数取值在最终绘回时归零红蓝。
    let levelsGreenOnly: Bool
    /// tag63的37采样常量；只允许附于完整Screen+Levels+MotionTile结果。
    let motionBlur: MetalMotionBlurUniforms?
    /// Glow第二轴局部结果与阈值；原图仍在texture中。
    let glow: MetalGlowInput?
    /// 层115有界MotionTile→Glow→Bulge结果的第二纹理与完整域映射。
    let tileGlowBulge: MetalTileGlowBulgeInput?
}

/// 一条图层mask在组栈中的边界及零面积恢复信息，不跨请求共享。
struct MetalMaskScope {
    /// 非零有限路径的GPU输入；nil表示零面积，正反向由进入时处理。
    let input: MetalMaskInput?
    /// 安装前的保守可见范围，退出时原样恢复。
    let previousLimit: RenderBounds?
    /// 对应beginMask所在的组深度，预合成整棵子树退出后才可关闭。
    let groupDepth: Int
    /// 进入时已排队的draw数，用于拒绝双mask下多个图像的先合成语义。
    let drawStart: Int
    /// 此作用域是否为可与另一条普通非反向单路径相交的来源。
    let simplePath: Bool
}
