import Metal

/// 把原内容与Glow两轴结果先合成局部纹理，供编码顺序在后的效果读取。
struct MetalGlowMergePass {
    /// Glow前完整输入附件；alpha仍只取它。
    let source: any MTLTexture
    /// 已完成两轴卷积的局部附件，尺寸可按Glow半径缩小。
    let blurred: any MTLTexture
    /// 与source同尺寸的独立BGRA8输出附件。
    let destination: any MTLTexture
    /// 上游GlowMerge的RGB除数，取当前源帧值。
    let threshold: Float

    /// 在后续效果采样前编码合并，拒绝纹理别名和不匹配的输入域。
    func encode(commandBuffer: any MTLCommandBuffer, pipeline: any MTLRenderPipelineState) throws {
        try Task.checkCancellation()
        guard source.pixelFormat == .bgra8Unorm, blurred.pixelFormat == .bgra8Unorm,
              destination.pixelFormat == .bgra8Unorm, source.sampleCount == 1,
              blurred.sampleCount == 1, destination.sampleCount == 1,
              source.width > 0, source.height > 0, blurred.width > 0, blurred.height > 0,
              destination.width == source.width, destination.height == source.height,
              source !== destination, blurred !== destination, threshold.isFinite else {
            throw PAGError.renderingFailure("glowMergeDimensions")
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
        encoder.label = "pag.local.glow.merge"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
            width: Double(destination.width), height: Double(destination.height), znear: 0, zfar: 1))
        encoder.setCullMode(.none)
        encoder.setRenderPipelineState(pipeline)
        var bounds = SIMD4<Float>(-1, 1, 1, -1)
        var divisor = threshold
        encoder.setVertexBytes(&bounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&divisor, length: MemoryLayout<Float>.stride, index: 1)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(blurred, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
