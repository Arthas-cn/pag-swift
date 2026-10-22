import Metal

/// Glow的一轴GPU局部卷积；仅消费完整输入域纹理，不自动建立整帧中转。
struct MetalGlowBlurPass {
    /// 上一效果或上一轴已经完成的BGRA8输入。
    let source: any MTLTexture
    /// 本轴写入的独立BGRA8目标；调用方负责预算、保活和归还。
    let destination: any MTLTexture
    /// 从上游完整输入域计算的两轴目标尺寸及步长。
    let sampling: GlowSampling
    /// true表示第一轴缩小，false表示第二轴维持目标尺寸。
    let horizontal: Bool

    /// 编码一轴五点核；无效尺寸或同纹理读写在提交前失败。
    func encode(commandBuffer: any MTLCommandBuffer, pipeline: any MTLRenderPipelineState) throws {
        try Task.checkCancellation()
        let sourceWidth = horizontal ? sampling.inputWidth : sampling.blurWidth
        let sourceHeight = horizontal ? sampling.inputHeight : sampling.blurHeight
        guard source.pixelFormat == .bgra8Unorm, destination.pixelFormat == .bgra8Unorm,
              source.sampleCount == 1, destination.sampleCount == 1,
              source.width == Int(sourceWidth), source.height == Int(sourceHeight),
              destination.width == Int(sampling.blurWidth), destination.height == Int(sampling.blurHeight),
              source !== destination else {
            throw PAGError.renderingFailure("metalGlowDimensions")
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
        encoder.label = horizontal ? "pag.local.glow.blur.x" : "pag.local.glow.blur.y"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
            width: Double(destination.width), height: Double(destination.height), znear: 0, zfar: 1))
        encoder.setCullMode(.none)
        encoder.setRenderPipelineState(pipeline)
        var bounds = SIMD4<Float>(-1, 1, 1, -1)
        var step = horizontal ? SIMD4(sampling.horizontalStep, 0, 0, 0) :
            SIMD4<Float>(0, sampling.verticalStep, 0, 0)
        encoder.setVertexBytes(&bounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&step, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}

/// 根或祖先颜色pass读取的两轴结果；原输入仍单独占据第一纹理。
struct MetalGlowInput {
    /// 两轴均完成且保活到GPU结束的局部结果。
    let texture: any MTLTexture
    /// 上游Merge的RGB除数，按当前合成帧采样。
    let threshold: Float
}

/// 在内容pass之后、消费该组结果的颜色pass之前执行的两个Glow局部pass。
struct MetalGlowWork {
    /// 完整输入的局部内容附件；必须先经对应内容pass写完。
    let source: MetalGroupAttachment
    /// 第一轴的缩小结果，第二轴以其为输入。
    let horizontal: MetalGroupAttachment
    /// 第二轴结果，由最终Merge片元读取。
    let vertical: MetalGroupAttachment
    /// 两轴的完整输入域尺寸与UV步长。
    let sampling: GlowSampling

    /// 顺序编码横轴和纵轴，中间BGRA8量化由附件格式执行。
    func encode(commandBuffer: any MTLCommandBuffer, pipeline: any MTLRenderPipelineState) throws {
        try MetalGlowBlurPass(source: source.texture, destination: horizontal.texture,
                              sampling: sampling, horizontal: true)
            .encode(commandBuffer: commandBuffer, pipeline: pipeline)
        try MetalGlowBlurPass(source: horizontal.texture, destination: vertical.texture,
                              sampling: sampling, horizontal: false)
            .encode(commandBuffer: commandBuffer, pipeline: pipeline)
    }
}
