import Metal

/// 与MSL中两个16字节向量严格一致的单轴Blur参数。
private struct MetalFastBlurUniforms {
    /// 输入像素尺寸、半核半径和轴索引。
    let sourceAndKernel: SIMD4<UInt32>
    /// 输出到源的平移与边缘模式，第三分量为Clamp标记。
    let shiftAndMode: SIMD4<Int32>
}

/// FastBlur单轴GPU卷积；组工作图负责Glow前序输入与扩边布局。
struct MetalFastBlurPass {
    /// 上一效果或上一轴输出的完整局部纹理。
    let source: any MTLTexture
    /// 当前轴独立写入的BGRA8局部附件。
    let destination: any MTLTexture
    /// TGFX的有限sigma归一化半核，范围为零到radius。
    let axis: FeatherGaussianAxis
    /// true使用水平邻域，false使用垂直邻域。
    let horizontal: Bool
    /// 输出坐标减去该水平偏移后才对应输入像素。
    let shiftX: Int
    /// 输出坐标减去该垂直偏移后才对应输入像素。
    let shiftY: Int
    /// true为重复边缘Clamp；false为源外透明Decal。
    let repeatEdgePixels: Bool

    /// 编码一轴，禁止读写同一纹理；附件保活和归还由拥有者负责。
    func encode(commandBuffer: any MTLCommandBuffer, pipeline: any MTLRenderPipelineState) throws {
        try Task.checkCancellation()
        guard source.pixelFormat == .bgra8Unorm, destination.pixelFormat == .bgra8Unorm,
              source.sampleCount == 1, destination.sampleCount == 1,
              source.width > 0, source.height > 0, destination.width > 0, destination.height > 0,
              source !== destination,
              let sourceWidth = UInt32(exactly: source.width),
              let sourceHeight = UInt32(exactly: source.height),
              let radius = UInt32(exactly: axis.radius),
              let offsetX = Int32(exactly: shiftX), let offsetY = Int32(exactly: shiftY) else {
            throw PAGError.renderingFailure("fastBlurDimensions")
        }
        let pass = MTLRenderPassDescriptor()
        guard let color = pass.colorAttachments[0] else {
            throw PAGError.renderingFailure("metalColorAttachment")
        }
        color.texture = destination
        color.loadAction = .clear
        color.storeAction = .store
        color.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw PAGError.renderingFailure("metalRenderEncoder")
        }
        defer { encoder.endEncoding() }
        encoder.label = horizontal ? "pag.local.fastblur.x" : "pag.local.fastblur.y"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
            width: Double(destination.width), height: Double(destination.height), znear: 0, zfar: 1))
        encoder.setCullMode(.none)
        encoder.setRenderPipelineState(pipeline)
        var bounds = SIMD4<Float>(-1, 1, 1, -1)
        var uniforms = MetalFastBlurUniforms(
            sourceAndKernel: SIMD4(sourceWidth, sourceHeight, radius, horizontal ? 0 : 1),
            shiftAndMode: SIMD4(offsetX, offsetY, repeatEdgePixels ? 1 : 0, 0))
        encoder.setVertexBytes(&bounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalFastBlurUniforms>.stride, index: 2)
        axis.weights.withUnsafeBufferPointer { weights in
            encoder.setFragmentBytes(weights.baseAddress!, length: weights.count * MemoryLayout<Float>.stride,
                                     index: 1)
        }
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}

/// Glow之后的FastBlur阶段图；附件所有权仍由根帧批次统一保留和归还。
struct MetalFastBlurWork {
    /// 已完成Glow Merge的完整局部内容输入。
    let source: any MTLTexture
    /// 按有符号源样本范围线性缩采后的输入附件。
    let reduced: any MTLTexture
    /// 水平轴正sigma时的独立卷积附件；零轴不分配。
    let horizontal: (any MTLTexture)?
    /// 垂直轴正sigma时的独立卷积附件；零轴不分配。
    let vertical: (any MTLTexture)?
    /// 最终按Clamp或Decal范围回放大的局部结果。
    let output: any MTLTexture
    /// 两轴共同使用的原图尺寸、缩采比例、半核及最终范围。
    let layout: FastBlurTextureLayout
    /// Clamp重复边缘与Decal透明边界必须贯穿缩采和卷积。
    let repeatEdgePixels: Bool

    /// 按缩采、有效轴卷积、回放大顺序编码；中间BGRA8量化由实际附件执行。
    func encode(commandBuffer: any MTLCommandBuffer, pipelines: MetalPipelines) throws {
        try Task.checkCancellation()
        guard source.width == layout.x.sourceLength, source.height == layout.y.sourceLength,
              reduced.width == layout.x.reducedLength, reduced.height == layout.y.reducedLength,
              output.width == layout.x.outputLength, output.height == layout.y.outputLength,
              (horizontal != nil) == (layout.x.kernel != nil),
              (vertical != nil) == (layout.y.kernel != nil),
              horizontal == nil || (horizontal?.width == reduced.width && horizontal?.height == reduced.height),
              vertical == nil || (vertical?.width == reduced.width && vertical?.height == reduced.height) else {
            throw PAGError.renderingFailure("fastBlurWorkDimensions")
        }
        let xInput = layout.x.sourceTransform, yInput = layout.y.sourceTransform
        try MetalFastBlurResamplePass(source: source, destination: reduced,
            transform: SIMD4(xInput.scale, yInput.scale, xInput.translate, yInput.translate),
            repeatEdgePixels: repeatEdgePixels)
            .encode(commandBuffer: commandBuffer, pipeline: pipelines.fastBlurResample)
        var current: any MTLTexture = reduced
        if let axis = layout.x.kernel, let horizontal {
            try MetalFastBlurPass(source: current, destination: horizontal, axis: axis,
                horizontal: true, shiftX: 0, shiftY: 0, repeatEdgePixels: repeatEdgePixels)
                .encode(commandBuffer: commandBuffer, pipeline: pipelines.fastBlur)
            current = horizontal
        }
        if let axis = layout.y.kernel, let vertical {
            try MetalFastBlurPass(source: current, destination: vertical, axis: axis,
                horizontal: false, shiftX: 0, shiftY: 0, repeatEdgePixels: repeatEdgePixels)
                .encode(commandBuffer: commandBuffer, pipeline: pipelines.fastBlur)
            current = vertical
        }
        let xOutput = layout.x.outputTransform, yOutput = layout.y.outputTransform
        try MetalFastBlurResamplePass(source: current, destination: output,
            transform: SIMD4(xOutput.scale, yOutput.scale, xOutput.translate, yOutput.translate),
            repeatEdgePixels: repeatEdgePixels)
            .encode(commandBuffer: commandBuffer, pipeline: pipelines.fastBlurResample)
    }
}

/// 同一内容pass后的Glow Merge与FastBlur，严格按效果标签顺序编码。
struct MetalGlowFastBlurWork {
    /// 先把Glow合并结果写成FastBlur可采样的完整输入。
    let merge: MetalGlowMergePass
    /// 再执行缩采、分轴Gaussian和最终范围回放大。
    let blur: MetalFastBlurWork

    /// 内容和Glow两轴已编码后调用；局部输出必须早于祖先颜色pass。
    func encode(commandBuffer: any MTLCommandBuffer, pipelines: MetalPipelines) throws {
        try merge.encode(commandBuffer: commandBuffer, pipeline: pipelines.glowMergeLocal)
        try blur.encode(commandBuffer: commandBuffer, pipelines: pipelines)
    }
}
