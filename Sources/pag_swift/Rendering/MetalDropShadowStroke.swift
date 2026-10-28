import Metal

/// 一条spread一扩散样式的有界局部尺寸；源图在halo位置，实际采样半径另受25像素上限。
struct DropShadowStrokeLayout {
    /// 输出左、右相同的整数透明边距。
    let haloX: Int
    /// 输出上、下相同的整数透明边距。
    let haloY: Int
    /// 合成扩散后的正像素宽度。
    let width: Int
    /// 合成扩散后的正像素高度。
    let height: Int

    /// 按上游filterBounds的未钳半径扩边；过大尺寸在借GPU附件前原子失败。
    static func make(size: ScenePoint, width: Int, height: Int) throws -> DropShadowStrokeLayout {
        guard size.x.isFinite, size.y.isFinite, size.x >= 0, size.y >= 0,
              size.x <= 8_192, size.y <= 8_192,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              let haloX = Int(exactly: size.x.rounded(.up)),
              let haloY = Int(exactly: size.y.rounded(.up)) else {
            throw PAGError.resourceLimitExceeded("dropShadowStrokeDimensions")
        }
        let outputWidth = width.addingReportingOverflow(haloX * 2)
        let outputHeight = height.addingReportingOverflow(haloY * 2)
        guard !outputWidth.overflow, !outputHeight.overflow,
              outputWidth.partialValue <= 16_384, outputHeight.partialValue <= 16_384,
              UInt128(outputWidth.partialValue) * UInt128(outputHeight.partialValue) <= 16_777_216 else {
            throw PAGError.resourceLimitExceeded("dropShadowStrokeDimensions")
        }
        return DropShadowStrokeLayout(haloX: haloX, haloY: haloY,
            width: outputWidth.partialValue, height: outputHeight.partialValue)
    }
}

/// 与MSL两个16字节向量相同的正负半圆采样常量。
private struct MetalDropShadowStrokeUniforms {
    /// 源纹理宽高与显示像素半径。
    let sourceAndRadius: SIMD4<Float>
    /// 源图在输出附件的左上整数起点及Thick模式标志。
    let originAndMode: SIMD4<Float>
}

/// SolidStroke的Normal/Thick椭圆样本在GPU形成二值alpha，根pass再着样式颜色。
struct MetalDropShadowStrokePass {
    /// 局部内容或前一效果提供的源纹理。
    let source: any MTLTexture
    /// 本条样式自己的局部输出附件，由根批次保活和归还。
    let destination: MetalGroupAttachment
    /// 源滤镜尚未钳到25像素的显示半径。
    let size: ScenePoint
    /// 源style.size×spread达到12时加半半径采样圈。
    let thick: Bool
    /// 原图在输出附件中的整数偏移。
    let haloX: Int
    /// 原图在输出附件中的纵向整数偏移。
    let haloY: Int

    /// 写满本条样式的局部扩散纹理；源外取零，不读回CPU。
    func encode(commandBuffer: any MTLCommandBuffer, pipeline: any MTLRenderPipelineState) throws {
        try Task.checkCancellation()
        let target = destination.texture
        guard source.pixelFormat == .bgra8Unorm, target.pixelFormat == .bgra8Unorm,
              source.sampleCount == 1, target.sampleCount == 1,
              source.width > 0, source.height > 0 else {
            throw PAGError.renderingFailure("dropShadowStrokeTexture")
        }
        let pass = MTLRenderPassDescriptor()
        guard let color = pass.colorAttachments[0] else { throw PAGError.renderingFailure("metalColorAttachment") }
        color.texture = target
        color.loadAction = .clear
        color.storeAction = .store
        color.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw PAGError.renderingFailure("metalRenderEncoder")
        }
        defer { encoder.endEncoding() }
        encoder.label = "pag.local.dropShadow.stroke"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
            width: Double(target.width), height: Double(target.height), znear: 0, zfar: 1))
        encoder.setCullMode(.none)
        encoder.setRenderPipelineState(pipeline)
        var bounds = SIMD4<Float>(-1, 1, 1, -1)
        var uniforms = MetalDropShadowStrokeUniforms(
            sourceAndRadius: SIMD4(Float(source.width), Float(source.height), Float(size.x), Float(size.y)),
            originAndMode: SIMD4(Float(haloX), Float(haloY), thick ? 1 : 0, 0))
        guard (0..<4).allSatisfy({ uniforms.sourceAndRadius[$0].isFinite }) else {
            throw PAGError.renderingFailure("dropShadowStrokeSize")
        }
        encoder.setVertexBytes(&bounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalDropShadowStrokeUniforms>.stride, index: 1)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
