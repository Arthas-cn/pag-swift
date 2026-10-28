import Metal

/// 只在后台owner创建并保活的基础绘制管线；不暴露系统对象或创建最终画面纹理。
struct MetalPipelines {
    /// 预乘纯色填充，支持真实矩形裁剪。
    let solid: any MTLRenderPipelineState
    /// 预乘RGBA输入采样，与纯色使用相同SrcOver混合。
    let image: any MTLRenderPipelineState
    /// 完整Screen图层结果采用TGFX等价的预乘颜色固定混合系数。
    let screenImage: any MTLRenderPipelineState
    /// tag57静态绿通道Levels先于整层Screen，不另借效果附件。
    let screenGreenImage: any MTLRenderPipelineState
    /// 真实预合成[57,56]先按完整输入域平铺、再保留绿色并Screen混合。
    let screenGreenMotionTileImage: any MTLRenderPipelineState
    /// 真实预合成[57,56]后按tag63做37次采样，再以Screen写当前显示附件。
    let screenGreenMotionTileBlurImage: any MTLRenderPipelineState
    /// 无前置Effects预合成的37样本MotionBlur，输入是有界内容附件，结果直写drawable。
    let mappedMotionBlurImage: any MTLRenderPipelineState
    /// Image层tag56在当前颜色附件直接重复输入纹理，无整帧效果副本。
    let motionTileImage: any MTLRenderPipelineState
    /// 图像层tag56结果再做tag63采样，直接写当前颜色目标。
    let motionTileBlurImage: any MTLRenderPipelineState
    /// 预合成MotionTile在完整语义域求值，只写后续Glow/Bulge所需的局部样本。
    let mappedMotionTile: any MTLRenderPipelineState
    /// 祖先普通路径蒙版与平铺图像在同一实际draw相乘。
    let maskedMotionTileImage: any MTLRenderPipelineState
    /// Image层tag59在当前颜色附件直接反采样原图像纹理。
    let bulgeImage: any MTLRenderPipelineState
    /// 祖先普通mask在凸出后的最终draw逐像素消费。
    let maskedBulgeImage: any MTLRenderPipelineState
    /// Text层Bulge在根drawable读取有界合成字形纹理，滤镜域仍为父合成尺寸。
    let textBulgeImage: any MTLRenderPipelineState
    /// 单独CornerPin直接在根颜色附件作逆投影采样。
    let cornerPinImage: any MTLRenderPipelineState
    /// MotionTile输出再经过CornerPin，二者在一个片元按上游顺序采样。
    let motionTileCornerPinImage: any MTLRenderPipelineState
    /// CornerPin输出再经过Bulge，二者在一个片元按上游顺序采样。
    let cornerPinBulgeImage: any MTLRenderPipelineState
    /// 两条非反向普通路径在同一图像draw上逐像素相乘，无局部颜色中转。
    let doubleMaskedImage: any MTLRenderPipelineState
    /// 用局部图层内容的alpha着色下方投影，不携带源内容RGB。
    let shadowImage: any MTLRenderPipelineState
    /// 直接从硬解NV12采样并预乘PAG alpha，最终仍使用同一SrcOver显示附件。
    let video: any MTLRenderPipelineState
    /// 有界解析渐变共享覆盖和SrcOver，直接写当前显示附件。
    let gradient: any MTLRenderPipelineState
    /// 超过解析八段时由小输入LUT采样，仍写当前颜色附件。
    let gradientTexture: any MTLRenderPipelineState
    /// 普通路径裁剪下的纯色绘制，额外逐draw乘有限或补集coverage。
    let maskedSolid: any MTLRenderPipelineState
    /// 普通路径裁剪下的图片或Picture采样。
    let maskedImage: any MTLRenderPipelineState
    /// 普通路径裁剪下的双平面视频采样。
    let maskedVideo: any MTLRenderPipelineState
    /// 普通路径裁剪下的解析渐变绘制。
    let maskedGradient: any MTLRenderPipelineState
    /// 普通路径蒙版下的输入LUT渐变。
    let maskedGradientTexture: any MTLRenderPipelineState
    /// 效果内容与同尺寸mask贴图在最终实际draw中只相乘一次。
    let featherImage: any MTLRenderPipelineState
    /// 两段局部颜色图按源alpha/luma及反向模式只在最终组合处相乘。
    let trackMatteImage: any MTLRenderPipelineState
    /// 祖先普通路径mask在轨道遮罩合成结果上一次消费，源局部颜色不预先裁剪。
    let maskedTrackMatteImage: any MTLRenderPipelineState
    /// 效果专用局部贴图按源顺序SrcOver拷入mask附件。
    let featherCopy: any MTLRenderPipelineState
    /// 以TGFX半核权重对单项alpha做有界分轴Gaussian，源范围外按Decal取零。
    let featherBlur: any MTLRenderPipelineState
    /// 大sigma只对单项效果局部纹理线性降采样/回放大，不触碰最终drawable。
    let featherResample: any MTLRenderPipelineState
    /// 上游SolidStroke的正负半圆采样，在有界局部附件形成二值扩散alpha。
    let shadowStroke: any MTLRenderPipelineState
    /// Glow两轴各五点的局部BGRA8卷积；每轴独立量化后再进入下一轴。
    let glowBlur: any MTLRenderPipelineState
    /// Glow按完整平铺网格求值、仅写实际可见且供Bulge采样的局部两轴附件。
    let mappedGlowBlur: any MTLRenderPipelineState
    /// 局部MotionTile和Glow结果在实际颜色目标完成Glow合并与Bulge逆采样。
    let tileGlowBulgeImage: any MTLRenderPipelineState
    /// Glow原内容与两轴结果按同一UV合并，并直接写当前颜色目标。
    let glowImage: any MTLRenderPipelineState
    /// Glow在后续效果前先写局部BGRA8完整结果，根pass不执行提前合并。
    let glowMergeLocal: any MTLRenderPipelineState
    /// FastBlur单轴Gaussian按Clamp或透明边界卷积有界BGRA8附件。
    let fastBlur: any MTLRenderPipelineState
    /// FastBlur的像素中心缩采与回放大，仅作用于滤镜局部附件。
    let fastBlurResample: any MTLRenderPipelineState
    /// Shape整层源图的Angle渐变叠加只写有界局部结果，根pass仍直画drawable。
    let gradientOverlay: any MTLRenderPipelineState
    /// Apple GPU从当前颜色附件读取背景的HardLight；非Apple设备仅该材料明确unsupported。
    let hardLightImage: (any MTLRenderPipelineState)?
    /// Track Matte拥有者在遮罩结果上读取背景作HardLight；非Apple设备仅此材质不可用。
    let hardLightTrackMatteImage: (any MTLRenderPipelineState)?

    /// 首次使用时编译共享MSL并创建管线；任何编译/创建错误转换为可跨actor的领域错误。
    init(device: any MTLDevice) throws {
        try Task.checkCancellation()
        do {
            let programmableBlend = device.supportsFamily(.apple2)
            let shader = MetalShaderSource.source +
                (programmableBlend ? MetalHardLightShaderSource.source : "")
            let library = try device.makeLibrary(source: shader, options: nil)
            solid = try Self.make(device: device, library: library, fragment: "pagSolid")
            image = try Self.make(device: device, library: library, fragment: "pagImage")
            screenImage = try Self.make(device: device, library: library, fragment: "pagImage", screenBlend: true)
            screenGreenImage = try Self.make(device: device, library: library,
                fragment: "pagScreenGreenImage", screenBlend: true)
            screenGreenMotionTileImage = try Self.make(device: device, library: library,
                fragment: "pagScreenGreenMotionTileImage", screenBlend: true)
            screenGreenMotionTileBlurImage = try Self.make(device: device, library: library,
                fragment: "pagScreenGreenMotionTileBlurImage", screenBlend: true)
            mappedMotionBlurImage = try Self.make(device: device, library: library,
                fragment: "pagMappedMotionBlurImage")
            motionTileImage = try Self.make(device: device, library: library, fragment: "pagMotionTileImage")
            motionTileBlurImage = try Self.make(device: device, library: library,
                fragment: "pagMotionTileBlurImage")
            mappedMotionTile = try Self.make(device: device, library: library,
                fragment: "pagMappedMotionTile", vertexName: "pagFeatherCopyVertex")
            maskedMotionTileImage = try Self.make(device: device, library: library,
                                                  fragment: "pagMaskedMotionTileImage")
            bulgeImage = try Self.make(device: device, library: library, fragment: "pagBulgeImage")
            maskedBulgeImage = try Self.make(device: device, library: library, fragment: "pagMaskedBulgeImage")
            textBulgeImage = try Self.make(device: device, library: library, fragment: "pagTextBulgeImage")
            cornerPinImage = try Self.make(device: device, library: library, fragment: "pagCornerPinImage")
            motionTileCornerPinImage = try Self.make(device: device, library: library,
                fragment: "pagMotionTileCornerPinImage")
            cornerPinBulgeImage = try Self.make(device: device, library: library,
                fragment: "pagCornerPinBulgeImage")
            doubleMaskedImage = try Self.make(device: device, library: library, fragment: "pagDoubleMaskedImage")
            shadowImage = try Self.make(device: device, library: library, fragment: "pagShadowImage")
            video = try Self.make(device: device, library: library, fragment: "pagVideo")
            gradient = try Self.make(device: device, library: library, fragment: "pagGradient")
            gradientTexture = try Self.make(device: device, library: library, fragment: "pagGradientTexture")
            maskedSolid = try Self.make(device: device, library: library, fragment: "pagMaskedSolid")
            maskedImage = try Self.make(device: device, library: library, fragment: "pagMaskedImage")
            maskedVideo = try Self.make(device: device, library: library, fragment: "pagMaskedVideo")
            maskedGradient = try Self.make(device: device, library: library, fragment: "pagMaskedGradient")
            maskedGradientTexture = try Self.make(device: device, library: library, fragment: "pagMaskedGradientTexture")
            featherImage = try Self.make(device: device, library: library, fragment: "pagFeatherImage")
            trackMatteImage = try Self.make(device: device, library: library, fragment: "pagTrackMatteImage")
            maskedTrackMatteImage = try Self.make(device: device, library: library, fragment: "pagMaskedTrackMatteImage")
            featherCopy = try Self.make(device: device, library: library, fragment: "pagFeatherCopy",
                                        vertexName: "pagFeatherCopyVertex")
            featherBlur = try Self.make(device: device, library: library, fragment: "pagFeatherBlur",
                                        vertexName: "pagFeatherCopyVertex")
            featherResample = try Self.make(device: device, library: library, fragment: "pagFeatherResample",
                                            vertexName: "pagFeatherCopyVertex")
            shadowStroke = try Self.make(device: device, library: library, fragment: "pagShadowStroke",
                                         vertexName: "pagFeatherCopyVertex")
            glowBlur = try Self.make(device: device, library: library, fragment: "pagGlowBlur",
                                    vertexName: "pagFeatherCopyVertex")
            mappedGlowBlur = try Self.make(device: device, library: library,
                fragment: "pagMappedGlowBlur", vertexName: "pagFeatherCopyVertex")
            tileGlowBulgeImage = try Self.make(device: device, library: library,
                fragment: "pagTileGlowBulgeImage")
            glowImage = try Self.make(device: device, library: library, fragment: "pagGlowImage")
            glowMergeLocal = try Self.make(device: device, library: library,
                fragment: "pagGlowMergeLocal", vertexName: "pagFeatherCopyVertex")
            fastBlur = try Self.make(device: device, library: library, fragment: "pagFastBlur",
                                     vertexName: "pagFeatherCopyVertex")
            fastBlurResample = try Self.make(device: device, library: library,
                fragment: "pagFastBlurResample", vertexName: "pagFeatherCopyVertex")
            gradientOverlay = try Self.make(device: device, library: library,
                fragment: "pagGradientOverlayAngle", vertexName: "pagFeatherCopyVertex")
            hardLightImage = programmableBlend ? try Self.make(device: device, library: library,
                fragment: "pagHardLightImage", hardLightBlend: true) : nil
            hardLightTrackMatteImage = programmableBlend ? try Self.make(device: device, library: library,
                fragment: "pagHardLightTrackMatteImage", hardLightBlend: true) : nil
        } catch is CancellationError { throw CancellationError() }
        catch { throw PAGError.renderingFailure("metalPipeline: \(error.localizedDescription)") }
        try Task.checkCancellation()
    }

    /// 所有基础内容直接匹配BGRA8单采样drawable，输入已经预乘，不能再次使用sourceAlpha因子。
    private static func make(device: any MTLDevice, library: any MTLLibrary,
                             fragment: String, vertexName: String = "pagVertex",
                             screenBlend: Bool = false,
                             hardLightBlend: Bool = false) throws -> any MTLRenderPipelineState {
        guard let vertex = library.makeFunction(name: vertexName), let pixel = library.makeFunction(name: fragment) else {
            throw PAGError.renderingFailure("metalFunctionMissing")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = screenBlend ? "pag.\(fragment).screen" : "pag.\(fragment)"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = pixel
        descriptor.rasterSampleCount = 1
        guard let color = descriptor.colorAttachments[0] else { throw PAGError.renderingFailure("metalColorAttachment") }
        color.pixelFormat = .bgra8Unorm
        // framebuffer fetch的片元已经读出并算好完整结果，固定混合器再参与会重复合成。
        color.isBlendingEnabled = !hardLightBlend
        color.rgbBlendOperation = .add
        color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        // TGFX BlendFormula将Screen化为源One、目标OneMinusSrc；alpha仍按SrcOver。
        color.destinationRGBBlendFactor = screenBlend ? .oneMinusSourceColor : .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}
