import Metal

/// 与Metal片元三个16字节向量一致的缩采/回放大参数。
private struct MetalFastBlurResampleUniforms {
    /// 输出像素中心到输入像素坐标的缩放和平移。
    let transform: SIMD4<Float>
    /// 实际输入纹理宽高，后两分量用于对齐。
    let sourceSize: SIMD4<Float>
    /// 第一分量为Clamp开关，后面保留对齐。
    let edgeMode: SIMD4<Int32>
}

/// FastBlur局部线性重采样，覆盖大sigma缩采和取整后回放大两个方向。
struct MetalFastBlurResamplePass {
    /// 上一效果或两轴结果纹理，必须已写完且不能与目标同一张。
    let source: any MTLTexture
    /// 本pass独占的局部BGRA8目标纹理。
    let destination: any MTLTexture
    /// 输出像素中心到输入像素坐标的横纵映射。
    let transform: SIMD4<Float>
    /// 输入域外重复边缘或透明，最终回放大的坐标通常不会出界。
    let repeatEdgePixels: Bool

    /// 编码一次完整局部重采样，拒绝无穷变换和同纹理读写。
    func encode(commandBuffer: any MTLCommandBuffer, pipeline: any MTLRenderPipelineState) throws {
        try Task.checkCancellation()
        guard source.pixelFormat == .bgra8Unorm, destination.pixelFormat == .bgra8Unorm,
              source.sampleCount == 1, destination.sampleCount == 1,
              source.width > 0, source.height > 0, destination.width > 0, destination.height > 0,
              source !== destination, transform.x > 0, transform.y > 0,
              (0..<4).allSatisfy({ transform[$0].isFinite }) else {
            throw PAGError.renderingFailure("fastBlurResampleDimensions")
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
        encoder.label = "pag.local.fastblur.resample"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
            width: Double(destination.width), height: Double(destination.height), znear: 0, zfar: 1))
        encoder.setCullMode(.none)
        encoder.setRenderPipelineState(pipeline)
        var bounds = SIMD4<Float>(-1, 1, 1, -1)
        var uniforms = MetalFastBlurResampleUniforms(
            transform: transform, sourceSize: SIMD4(Float(source.width), Float(source.height), 0, 0),
            edgeMode: SIMD4(repeatEdgePixels ? 1 : 0, 0, 0, 0))
        encoder.setVertexBytes(&bounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalFastBlurResampleUniforms>.stride,
                                 index: 1)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
