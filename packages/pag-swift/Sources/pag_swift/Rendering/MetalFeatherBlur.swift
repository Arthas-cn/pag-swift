import Metal

/// 与MSL两个16字节向量一致的一轴卷积常量，CPU只准备核、GPU按源边界取Decal。
private struct MetalFeatherBlurUniforms {
    /// 源宽高、半径与轴方向；0为水平、1为垂直。
    let sourceAndKernel: SIMD4<UInt32>
    /// 输出像素减去此偏移后才对应源图像坐标。
    let shift: SIMD4<Int32>
}

/// 单次水平或垂直Gaussian的私有局部pass；源和目标借用直到GPU完成均由根批次保活。
struct MetalFeatherBlurPass {
    /// 已完成上一步绘制或卷积的输入纹理。
    let source: any MTLTexture
    /// 当前轴卷积写入的有界局部附件。
    let destination: MetalGroupAttachment
    /// 上游半核权重，编码时以常量字节复制进command buffer。
    let axis: FeatherGaussianAxis
    /// true用水平偏移，false用垂直偏移。
    let horizontal: Bool
    /// 当前输出比源图像左侧多出的透明像素数。
    let shiftX: Int
    /// 当前输出比源图像上侧多出的透明像素数。
    let shiftY: Int

    /// 在单个clear的BGRA8附件执行完整一轴卷积；任何越界样本按透明Decal处理。
    func encode(commandBuffer: any MTLCommandBuffer, pipeline: any MTLRenderPipelineState) throws {
        try Task.checkCancellation()
        guard source.pixelFormat == .bgra8Unorm, destination.texture.pixelFormat == .bgra8Unorm,
              source.sampleCount == 1, destination.texture.sampleCount == 1,
              let sourceWidth = UInt32(exactly: source.width), let sourceHeight = UInt32(exactly: source.height),
              let radius = UInt32(exactly: axis.radius),
              let offsetX = Int32(exactly: shiftX), let offsetY = Int32(exactly: shiftY) else {
            throw PAGError.renderingFailure("featherBlurDimensions")
        }
        let texture = destination.texture
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
        encoder.label = horizontal ? "pag.local.feather.blur.x" : "pag.local.feather.blur.y"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
            width: Double(texture.width), height: Double(texture.height), znear: 0, zfar: 1))
        encoder.setCullMode(.none)
        encoder.setRenderPipelineState(pipeline)
        var bounds = SIMD4<Float>(-1, 1, 1, -1)
        var uniforms = MetalFeatherBlurUniforms(
            sourceAndKernel: SIMD4(sourceWidth, sourceHeight, radius, horizontal ? 0 : 1),
            shift: SIMD4(offsetX, offsetY, 0, 0))
        encoder.setVertexBytes(&bounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalFeatherBlurUniforms>.stride, index: 2)
        axis.weights.withUnsafeBufferPointer { weights in
            encoder.setFragmentBytes(weights.baseAddress!, length: weights.count * MemoryLayout<Float>.stride, index: 1)
        }
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
