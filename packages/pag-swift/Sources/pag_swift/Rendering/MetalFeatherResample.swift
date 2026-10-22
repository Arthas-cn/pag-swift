import Metal

/// 大sigma局部重采样的MSL常量：输出像素中心映到输入像素坐标，再除以输入尺寸。
private struct MetalFeatherResampleUniforms {
    /// 两轴缩放与平移，依次为scaleX、scaleY、translateX、translateY。
    let transform: SIMD4<Float>
    /// 输入纹理宽高，后两分量仅用于16字节对齐。
    let sourceSize: SIMD4<Float>
}

/// 单项mask的大sigma线性降采样或回放大pass；源外由Metal Decal采样补透明。
struct MetalFeatherResamplePass {
    /// 由前一pass或原始项alpha提供的输入纹理。
    let source: any MTLTexture
    /// 当前局部pass的独占目标附件，直到GPU完成均由根批次保活。
    let destination: MetalGroupAttachment
    /// 输出像素中心到输入像素坐标的逐轴线性映射。
    let transform: SIMD4<Float>

    /// 构建一个已由纯值布局决定尺寸的局部pass；非法Float在编码前失败。
    init(source: any MTLTexture, destination: MetalGroupAttachment, transform: SIMD4<Float>) throws {
        guard (0..<4).allSatisfy({ transform[$0].isFinite }),
              transform.x > 0, transform.y > 0 else {
            throw PAGError.renderingFailure("featherResampleTransform")
        }
        self.source = source
        self.destination = destination
        self.transform = transform
    }

    /// 写满一张效果局部附件；生产不读回CPU，也不创建整帧显示纹理。
    func encode(commandBuffer: any MTLCommandBuffer, pipeline: any MTLRenderPipelineState) throws {
        try Task.checkCancellation()
        let texture = destination.texture
        guard source.pixelFormat == .bgra8Unorm, texture.pixelFormat == .bgra8Unorm,
              source.sampleCount == 1, texture.sampleCount == 1,
              source.width > 0, source.height > 0 else {
            throw PAGError.renderingFailure("featherResampleDimensions")
        }
        let pass = MTLRenderPassDescriptor()
        guard let color = pass.colorAttachments[0] else { throw PAGError.renderingFailure("metalColorAttachment") }
        color.texture = texture
        color.loadAction = .clear
        color.storeAction = .store
        color.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw PAGError.renderingFailure("metalRenderEncoder")
        }
        defer { encoder.endEncoding() }
        encoder.label = "pag.local.feather.resample"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
            width: Double(texture.width), height: Double(texture.height), znear: 0, zfar: 1))
        encoder.setCullMode(.none)
        encoder.setRenderPipelineState(pipeline)
        var bounds = SIMD4<Float>(-1, 1, 1, -1)
        var uniforms = MetalFeatherResampleUniforms(transform: transform,
            sourceSize: SIMD4(Float(source.width), Float(source.height), 0, 0))
        encoder.setVertexBytes(&bounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalFeatherResampleUniforms>.stride, index: 1)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
