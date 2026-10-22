import Metal

/// 完整预合成坐标到紧致MotionTile工作附件的映射，避免按300%输出尺寸分配纹理。
struct MetalMappedTileUniforms {
    /// 完整平铺输出在最终显示像素域的位置和尺寸。
    let outputRect: SIMD4<Float>
    /// 局部工作附件在最终显示像素域的原点；另外两项保留零。
    let localOrigin: SIMD4<Float>
    /// 完整输入单位坐标到紧致内容附件u的仿射系数。
    let sourceX: SIMD4<Float>
    /// 完整输入单位坐标到紧致内容附件v的仿射系数。
    let sourceY: SIMD4<Float>

    /// 使用同一帧布局和原预合成矩阵建立映射；不可表示的GPU常量明确拒绝。
    init(layout: TileGlowBulgeLayout, clip: FrameClip, contentRect: RenderPixelRect) throws {
        let bounds = layout.tileBounds
        let width = bounds.right - bounds.left
        let height = bounds.bottom - bounds.top
        guard width > 0, height > 0, contentRect.width > 0, contentRect.height > 0 else {
            throw PAGError.renderingFailure("mappedTileDimensions")
        }
        let source = try MetalTextBulgeMap(compositionSize: clip.size,
            compositionMatrix: clip.matrix, rect: contentRect)
        outputRect = SIMD4(Float(bounds.left), Float(bounds.top), Float(width), Float(height))
        localOrigin = SIMD4(Float(layout.sample.x), Float(layout.sample.y), 0, 0)
        sourceX = source.horizontal
        sourceY = source.vertical
        guard (0..<4).allSatisfy({ outputRect[$0].isFinite && localOrigin[$0].isFinite }),
              outputRect.z > 0, outputRect.w > 0 else {
            throw PAGError.unsupportedFeature("mappedTileCoordinates")
        }
    }
}

/// MotionTile在局部附件求值；上游完整输出尺寸只参与坐标计算，不决定附件尺寸。
struct MetalMappedMotionTilePass {
    /// 原预合成的有界内容附件。
    let source: any MTLTexture
    /// 当前帧Glow/Bulge将读取的独立BGRA8局部附件。
    let destination: any MTLTexture
    /// 输入纹理在最终显示域的真实整数范围。
    let contentRect: RenderPixelRect
    /// 本次局部附件与完整平铺输出的范围合同。
    let layout: TileGlowBulgeLayout
    /// 原预合成的完整尺寸及显示矩阵。
    let clip: FrameClip
    /// 上游MotionTile的当前帧参数。
    let tile: FrameMotionTile

    /// 编码局部平铺采样；独立读写附件和尺寸错误在提交前失败。
    func encode(commandBuffer: any MTLCommandBuffer, pipeline: any MTLRenderPipelineState) throws {
        try Task.checkCancellation()
        guard source.pixelFormat == .bgra8Unorm, destination.pixelFormat == .bgra8Unorm,
              source.sampleCount == 1, destination.sampleCount == 1,
              source.width == contentRect.width, source.height == contentRect.height,
              destination.width == layout.sample.width, destination.height == layout.sample.height,
              source !== destination else {
            throw PAGError.renderingFailure("mappedTileDimensions")
        }
        var map = try MetalMappedTileUniforms(layout: layout, clip: clip, contentRect: contentRect)
        var motion = try MetalMotionTileUniforms(tile)
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
        encoder.label = "pag.local.motionTile.mapped"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
            width: Double(destination.width), height: Double(destination.height), znear: 0, zfar: 1))
        encoder.setCullMode(.none)
        encoder.setRenderPipelineState(pipeline)
        var bounds = SIMD4<Float>(-1, 1, 1, -1)
        encoder.setVertexBytes(&bounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&map, length: MemoryLayout<MetalMappedTileUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&motion, length: MemoryLayout<MetalMotionTileUniforms>.stride, index: 2)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
