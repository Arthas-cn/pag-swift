import Metal

/// Glow局部两轴的GPU坐标：源和目标均可裁剪，但UV始终属于完整上游网格。
struct MetalMappedGlowUniforms {
    /// 当前目标矩形的完整网格原点与完整Glow网格尺寸。
    let destinationAndSize: SIMD4<Float>
    /// 当前源纹理在完整输入网格的位置和局部大小。
    let sourceRect: SIMD4<Float>
    /// 当前源所属完整网格宽高；其余字段保留零。
    let sourceSize: SIMD4<Float>
    /// 五点核在完整缩小网格中的归一化单轴步长。
    let step: SIMD4<Float>

    /// 首轴读完整MotionTile像素网格，次轴读局部横轴结果，二者使用相同完整Glow UV。
    init(layout: TileGlowBulgeLayout, grid: MappedGlowGrid, horizontal: Bool) throws {
        let target = horizontal ? grid.horizontal : grid.vertical
        let source: SIMD4<Double>
        if horizontal {
            source = SIMD4(Double(layout.sample.x - layout.rasterBounds.x),
                Double(layout.sample.y - layout.rasterBounds.y),
                Double(layout.sample.width), Double(layout.sample.height))
        } else {
            source = SIMD4(Double(grid.horizontal.x), Double(grid.horizontal.y),
                Double(grid.horizontal.width), Double(grid.horizontal.height))
        }
        destinationAndSize = SIMD4(Float(target.x), Float(target.y),
            Float(grid.sampling.blurWidth), Float(grid.sampling.blurHeight))
        sourceRect = SIMD4(Float(source.x), Float(source.y), Float(source.z), Float(source.w))
        sourceSize = horizontal ? SIMD4(Float(grid.sampling.inputWidth),
            Float(grid.sampling.inputHeight), 0, 0) :
            SIMD4(Float(grid.sampling.blurWidth), Float(grid.sampling.blurHeight), 0, 0)
        step = horizontal ? SIMD4(grid.sampling.horizontalStep, 0, 0, 0) :
            SIMD4<Float>(0, grid.sampling.verticalStep, 0, 0)
        guard (0..<4).allSatisfy({ destinationAndSize[$0].isFinite &&
              sourceRect[$0].isFinite && sourceSize[$0].isFinite && step[$0].isFinite }),
              sourceRect.z > 0, sourceRect.w > 0 else {
            throw PAGError.unsupportedFeature("mappedGlowCoordinates")
        }
    }
}

/// Glow分轴局部pass，按完整网格采样并由BGRA8附件在两轴之间量化。
struct MetalMappedGlowBlurPass {
    /// 前一效果或前一轴的局部纹理。
    let source: any MTLTexture
    /// 本轴的独立局部BGRA8纹理。
    let destination: any MTLTexture
    /// 完整输入与被Bulge读取的必要范围。
    let layout: TileGlowBulgeLayout
    /// 两轴各自的局部目标矩形。
    let grid: MappedGlowGrid
    /// true为横轴；false为纵轴。
    let horizontal: Bool

    /// 校验附件对应关系后编码五点核；同一纹理不得读写重叠。
    func encode(commandBuffer: any MTLCommandBuffer, pipeline: any MTLRenderPipelineState) throws {
        try Task.checkCancellation()
        let input = horizontal ? layout.sample : grid.horizontal
        let output = horizontal ? grid.horizontal : grid.vertical
        guard source.pixelFormat == .bgra8Unorm, destination.pixelFormat == .bgra8Unorm,
              source.sampleCount == 1, destination.sampleCount == 1,
              source.width == input.width, source.height == input.height,
              destination.width == output.width, destination.height == output.height,
              source !== destination else {
            throw PAGError.renderingFailure("mappedGlowDimensions")
        }
        var uniforms = try MetalMappedGlowUniforms(layout: layout, grid: grid,
            horizontal: horizontal)
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
        encoder.label = horizontal ? "pag.local.glow.mapped.x" : "pag.local.glow.mapped.y"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
            width: Double(destination.width), height: Double(destination.height), znear: 0, zfar: 1))
        encoder.setCullMode(.none)
        encoder.setRenderPipelineState(pipeline)
        var bounds = SIMD4<Float>(-1, 1, 1, -1)
        encoder.setVertexBytes(&bounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalMappedGlowUniforms>.stride, index: 1)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
