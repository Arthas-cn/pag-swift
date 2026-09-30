import Metal
import QuartzCore

/// 完整准备的单帧GPU输入，只允许在RenderOwner隔离域内编码。
struct MetalFrameBatch {
    /// 子组先于父组，最后一个pass直接指向drawable。
    let passes: [MetalFramePass]
    /// 同owner的附件池，归还只能发生在GPU结束后。
    let pool: MetalGroupPool
    /// 当前帧借用的局部附件，身份在整个GPU生命周期内有效。
    let loans: [MetalGroupAttachment]
    /// 所有图元共用的已编译基础管线。
    let pipelines: MetalPipelines
    /// 已上传的单帧凸裁剪边输入；draw常量按下标引用，GPU执行期间保持不变。
    let clipBuffer: any MTLBuffer
    /// 所有pass实际编码的图元数，包含必要的组结果图元。
    var drawCount: Int { passes.reduce(0) { $0 + $1.draws.count } }

    /// 提交前放弃或GPU已完成时归还；旧批次重复调用不能释放新的纹理借用。
    func releaseTransients() { for loan in loans { pool.release(loan) } }

    /// 直接把当前drawable设为唯一最终颜色附件；这里只编码，不决定是否允许present/commit。
    func encode(to drawable: any CAMetalDrawable, commandBuffer: any MTLCommandBuffer,
                geometry: DisplayGeometry) throws {
        try Task.checkCancellation()
        let texture = try Self.displayTexture(drawable, geometry: geometry)
        guard !passes.isEmpty, passes.last?.attachment == nil,
              loans.allSatisfy({ pool.contains($0) }) else {
            throw PAGError.renderingFailure("metalExpiredBatch")
        }
        for (index, pass) in passes.enumerated() {
            guard (pass.attachment == nil) == (index == passes.count - 1) else {
                throw PAGError.renderingFailure("metalPassOrder")
            }
            try encode(pass, texture: pass.attachment?.texture ?? texture, commandBuffer: commandBuffer)
        }
    }

    /// 直接将显示附件clear为透明；不编译着色器、不创建中间附件，也不伪造零时刻场景。
    static func clear(to drawable: any CAMetalDrawable, commandBuffer: any MTLCommandBuffer,
                      geometry: DisplayGeometry) throws {
        try Task.checkCancellation()
        let texture = try displayTexture(drawable, geometry: geometry)
        let encoder = try makeEncoder(texture: texture, commandBuffer: commandBuffer)
        encoder.label = "pag.clear.drawable"
        encoder.endEncoding()
    }

    /// 内容帧与清屏共同验证真实最终附件，不接受旧尺寸或不匹配格式的drawable。
    private static func displayTexture(_ drawable: any CAMetalDrawable, geometry: DisplayGeometry) throws -> any MTLTexture {
        let texture = drawable.texture
        guard texture.pixelFormat == .bgra8Unorm, texture.sampleCount == 1,
              texture.width == geometry.pixelWidth, texture.height == geometry.pixelHeight else {
            throw PAGError.renderingFailure("metalDrawableConfiguration")
        }
        return texture
    }

    /// 所有pass统一透明clear并store；只有调用方传入的真实附件会被修改。
    private static func makeEncoder(texture: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws -> any MTLRenderCommandEncoder {
        let descriptor = MTLRenderPassDescriptor()
        guard let color = descriptor.colorAttachments[0] else { throw PAGError.renderingFailure("metalColorAttachment") }
        color.texture = texture
        color.loadAction = .clear
        color.storeAction = .store
        color.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw PAGError.renderingFailure("metalRenderEncoder")
        }
        return encoder
    }

    /// 一个局部组或最终显示pass；附件间使用同一command buffer的顺序与默认hazard追踪。
    private func encode(_ pass: MetalFramePass, texture: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws {
        guard texture.width == pass.rect.width, texture.height == pass.rect.height else {
            throw PAGError.renderingFailure("metalPassDimensions")
        }
        let encoder = try Self.makeEncoder(texture: texture, commandBuffer: commandBuffer)
        defer { encoder.endEncoding() }
        encoder.label = pass.attachment == nil ? "pag.direct.drawable" : "pag.local.opacity"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(pass.rect.width),
                                        height: Double(pass.rect.height), znear: 0, zfar: 1))
        encoder.setCullMode(.none)
        for draw in pass.draws {
            try Task.checkCancellation()
            let pipeline = draw.gradient != nil ? pipelines.gradient :
                (draw.video != nil ? pipelines.video : (draw.texture == nil ? pipelines.solid : pipelines.image))
            encoder.setRenderPipelineState(pipeline)
            var uniforms = draw.uniforms
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalDrawUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalDrawUniforms>.stride, index: 1)
            encoder.setFragmentBuffer(clipBuffer, offset: 0, index: 2)
            encoder.setFragmentBuffer(draw.mesh.nodes, offset: 0, index: 3)
            encoder.setFragmentBuffer(draw.mesh.triangles, offset: 0, index: 4)
            encoder.setFragmentBuffer(draw.mesh.buffer, offset: 0, index: 5)
            if var gradient = draw.gradient {
                encoder.setFragmentBytes(&gradient, length: MemoryLayout<MetalGradientUniforms>.stride, index: 6)
                encoder.setFragmentTexture(nil, index: 0)
                encoder.setFragmentTexture(nil, index: 1)
            } else if let video = draw.video {
                var sampling = video.uniforms
                encoder.setFragmentBytes(&sampling, length: MemoryLayout<MetalVideoUniforms>.stride, index: 6)
                encoder.setFragmentTexture(video.luma, index: 0)
                encoder.setFragmentTexture(video.chroma, index: 1)
            } else {
                encoder.setFragmentTexture(draw.texture, index: 0)
                encoder.setFragmentTexture(nil, index: 1)
            }
            // 一个包围矩形只生成一次片元覆盖；内部三角形由片元累积后统一SrcOver。
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }
}

/// 一次基础绘制及其保活资源，不遵循Sendable，不进入FramePlan或UI域。
struct MetalDraw {
    /// 不可变GPU顶点和保活的CPU身份。
    let mesh: MetalMesh
    /// 图片或局部组纹理；nil时由video或纯色网格提供内容。
    let texture: (any MTLTexture)?
    /// 视频的完整双平面输入及CV包装；nil表示不是视频，与texture互斥。
    let video: MetalVideoInput?
    /// 有界渐变常量；与texture/video互斥，退化渐变已折入纯色。
    let gradient: MetalGradientUniforms?
    /// 已经准备好的112字节绘制常量，包含当前pass像素原点和覆盖查询变换。
    let uniforms: MetalDrawUniforms
    /// 此绘制的真实裁剪来源，便于核对组作用域；实际GPU边界在batch.clipBuffer内。
    let clips: MetalClipValues
}

/// 已经确定尺寸和常量的单个渲染pass，不包含公共离屏输出能力。
struct MetalFramePass {
    /// 当前附件在最终显示像素中的整数范围。
    let rect: RenderPixelRect
    /// 必要局部组借用；nil只允许用于最后的直接drawable pass。
    let attachment: MetalGroupAttachment?
    /// 按PAG顺序执行的完整绘制，保活缓存淘汰后的输入。
    let draws: [MetalDraw]
}
