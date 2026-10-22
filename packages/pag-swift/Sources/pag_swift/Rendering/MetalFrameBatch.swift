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
    /// 内容局部pass先于任何采样它的组或drawable pass编码。
    let pictureWorks: [MetalPictureWork]
    /// 羽化内容与各项alpha局部附件先于采样它们的根draw完成。
    let featherWorks: [MetalFeatherWork]
    /// 轨道遮罩的两段局部颜色批次，最终只由根pass读取。
    let trackMatteWorks: [MetalTrackMatteWork]
    /// 本帧投影的内容局部批次，输出仍由根pass直接写drawable。
    let dropShadowWorks: [MetalDropShadowWork]
    /// Text层Bulge的紧致内容局部批次，不建立整帧复制表面。
    let textBulgeWorks: [MetalTextBulgeWork]
    /// 仅根批次持有的Picture存储；局部批次自身不再递归生成Picture。
    let pictureStore: MetalPictureStore?
    /// 可选快照无法使用时的明确原因；不影响原命令绘制或GPU提交。
    let pictureMisses: [String]
    /// 所有pass实际编码的图元数，包含必要的组结果图元。
    var drawCount: Int {
        passes.reduce(0) { $0 + $1.draws.count }
        + pictureWorks.reduce(0) { $0 + $1.batch.drawCount }
        + featherWorks.reduce(0) { $0 + $1.drawCount }
        + trackMatteWorks.reduce(0) { $0 + $1.drawCount }
        + dropShadowWorks.reduce(0) { $0 + $1.drawCount }
        + textBulgeWorks.reduce(0) { $0 + $1.drawCount }
    }

    /// 提交前放弃或GPU已完成时归还；旧批次重复调用不能释放新的纹理借用。
    func releaseTransients() {
        for loan in loans { pool.release(loan) }
        for work in pictureWorks {
            work.batch.releaseTransients()
            pictureStore?.discard(work.lease)
        }
        for work in featherWorks { work.releaseTransients() }
        for work in trackMatteWorks { work.releaseTransients() }
        for work in dropShadowWorks { work.releaseTransients() }
        for work in textBulgeWorks { work.releaseTransients() }
    }

    /// GPU确已完成且请求代数仍有效后，才把新内容纹理从活动表移入LRU。
    func publishPictures() {
        for work in pictureWorks { pictureStore?.publish(work.lease) }
    }

    /// 直接把当前drawable设为唯一最终颜色附件；这里只编码，不决定是否允许present/commit。
    func encode(to drawable: any CAMetalDrawable, commandBuffer: any MTLCommandBuffer,
                geometry: DisplayGeometry) throws {
        try Task.checkCancellation()
        let texture = try Self.displayTexture(drawable, geometry: geometry)
        for work in pictureWorks {
            try work.batch.encodePicture(to: work.lease.picture.texture, commandBuffer: commandBuffer)
        }
        for work in featherWorks { try work.encode(commandBuffer: commandBuffer, pipelines: pipelines) }
        for work in trackMatteWorks { try work.encode(commandBuffer: commandBuffer) }
        for work in dropShadowWorks { try work.encode(commandBuffer: commandBuffer) }
        for work in textBulgeWorks { try work.encode(commandBuffer: commandBuffer) }
        try encodeContent(to: texture, commandBuffer: commandBuffer)
    }

    /// 供局部内容批次写有界私有纹理；其轨道遮罩与子投影须先完成，根批次仍直写drawable。
    func encodePicture(to texture: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws {
        guard pictureWorks.isEmpty, featherWorks.isEmpty, pictureStore == nil else {
            throw PAGError.renderingFailure("metalNestedPicture")
        }
        // 局部投影源可含一层真实TrackMatte，其结果须先于外层投影内容附件生成。
        for work in trackMatteWorks { try work.encode(commandBuffer: commandBuffer) }
        // 父投影的局部内容可包含子投影；子纹理必须先完成，父批次才能读取。
        for work in dropShadowWorks { try work.encode(commandBuffer: commandBuffer) }
        for work in textBulgeWorks { try work.encode(commandBuffer: commandBuffer) }
        try encodeContent(to: texture, commandBuffer: commandBuffer)
    }

    /// 两种最终附件共享同一顺序和尺寸校验，避免局部pass绕过基础绘制约束。
    private func encodeContent(to texture: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws {
        guard !passes.isEmpty, passes.last?.attachment == nil,
              loans.allSatisfy({ pool.contains($0) }) else {
            throw PAGError.renderingFailure("metalExpiredBatch")
        }
        guard texture.pixelFormat == .bgra8Unorm, texture.sampleCount == 1,
              texture.width == passes.last?.rect.width, texture.height == passes.last?.rect.height else {
            throw PAGError.renderingFailure("metalPassDimensions")
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
            let pipeline: any MTLRenderPipelineState
            if draw.screenBlend {
                // 子内容已在局部附件SrcOver合成，只有整层结果可用Screen系数写当前附件。
                guard draw.texture != nil, draw.mask == nil, draw.video == nil,
                      draw.gradient == nil, draw.featherMaskTexture == nil,
                      draw.trackMatteMode == nil, !draw.isShadow else {
                    throw PAGError.renderingFailure("metalScreenBlendMaterial")
                }
                if draw.motionTile != nil {
                    guard draw.levelsGreenOnly, draw.textBulgeMap != nil else {
                        throw PAGError.renderingFailure("metalScreenMotionTileMaterial")
                    }
                    pipeline = draw.motionBlur == nil ? pipelines.screenGreenMotionTileImage :
                        pipelines.screenGreenMotionTileBlurImage
                } else {
                    guard draw.motionBlur == nil else {
                        throw PAGError.renderingFailure("metalMotionBlurMaterial")
                    }
                    pipeline = draw.levelsGreenOnly ? pipelines.screenGreenImage : pipelines.screenImage
                }
            } else if draw.isShadow {
                guard draw.texture != nil, draw.featherMaskTexture == nil, draw.video == nil,
                      draw.gradient == nil, draw.mask == nil else {
                    throw PAGError.renderingFailure("metalDropShadowMaterial")
                }
                pipeline = pipelines.shadowImage
            } else if draw.parentMask != nil {
                guard draw.texture != nil, draw.mask != nil, draw.featherMaskTexture == nil,
                      draw.video == nil, draw.gradient == nil, draw.trackMatteMode == nil,
                      draw.motionTile == nil, draw.bulge == nil else {
                    throw PAGError.renderingFailure("metalDoubleMaskMaterial")
                }
                pipeline = pipelines.doubleMaskedImage
            } else if draw.cornerPin != nil {
                guard draw.texture != nil, draw.mask == nil, draw.featherMaskTexture == nil,
                      draw.video == nil, draw.gradient == nil, draw.trackMatteMode == nil,
                      !draw.isShadow else {
                    throw PAGError.renderingFailure("metalCornerPinMaterial")
                }
                if draw.motionTile != nil {
                    guard draw.bulge == nil else { throw PAGError.renderingFailure("metalCornerPinOrder") }
                    pipeline = pipelines.motionTileCornerPinImage
                } else if draw.bulge != nil {
                    pipeline = pipelines.cornerPinBulgeImage
                } else {
                    pipeline = pipelines.cornerPinImage
                }
            } else if draw.textBulgeMap != nil {
                guard draw.texture != nil, draw.bulge != nil, draw.mask == nil,
                      draw.featherMaskTexture == nil, draw.video == nil, draw.gradient == nil,
                      draw.motionTile == nil, draw.trackMatteMode == nil, !draw.isShadow else {
                    throw PAGError.renderingFailure("metalTextBulgeMaterial")
                }
                pipeline = pipelines.textBulgeImage
            } else if draw.motionTile != nil {
                guard draw.texture != nil, draw.featherMaskTexture == nil,
                      draw.video == nil, draw.gradient == nil,
                      draw.trackMatteMode == nil else {
                    throw PAGError.renderingFailure("metalMotionTileMaterial")
                }
                pipeline = draw.mask == nil ? pipelines.motionTileImage : pipelines.maskedMotionTileImage
            } else if draw.bulge != nil {
                guard draw.texture != nil, draw.featherMaskTexture == nil,
                      draw.video == nil, draw.gradient == nil,
                      draw.trackMatteMode == nil else {
                    throw PAGError.renderingFailure("metalBulgeMaterial")
                }
                pipeline = draw.mask == nil ? pipelines.bulgeImage : pipelines.maskedBulgeImage
            } else if let mode = draw.trackMatteMode {
                guard draw.texture != nil, draw.featherMaskTexture != nil,
                      draw.video == nil, draw.gradient == nil else {
                    throw PAGError.renderingFailure("metalTrackMatteMaterial")
                }
                guard mode != .none else { throw PAGError.renderingFailure("metalTrackMatteMode") }
                pipeline = draw.mask == nil ? pipelines.trackMatteImage : pipelines.maskedTrackMatteImage
            } else if draw.featherMaskTexture != nil {
                guard draw.mask == nil, draw.texture != nil, draw.video == nil, draw.gradient == nil else {
                    throw PAGError.renderingFailure("metalFeatherMaterial")
                }
                pipeline = pipelines.featherImage
            } else if draw.mask != nil {
                pipeline = draw.gradient != nil ?
                    (draw.texture != nil ? pipelines.maskedGradientTexture : pipelines.maskedGradient) :
                    (draw.video != nil ? pipelines.maskedVideo :
                     (draw.texture == nil ? pipelines.maskedSolid : pipelines.maskedImage))
            } else {
                pipeline = draw.gradient != nil ?
                    (draw.texture != nil ? pipelines.gradientTexture : pipelines.gradient) :
                    (draw.video != nil ? pipelines.video : (draw.texture == nil ? pipelines.solid : pipelines.image))
            }
            encoder.setRenderPipelineState(pipeline)
            var uniforms = draw.uniforms
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalDrawUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalDrawUniforms>.stride, index: 1)
            encoder.setFragmentBuffer(clipBuffer, offset: 0, index: 2)
            encoder.setFragmentBuffer(draw.mesh.nodes, offset: 0, index: 3)
            encoder.setFragmentBuffer(draw.mesh.triangles, offset: 0, index: 4)
            encoder.setFragmentBuffer(draw.mesh.buffer, offset: 0, index: 5)
            if let mode = draw.trackMatteMode {
                var rawMode = UInt32(mode.rawValue)
                encoder.setFragmentBytes(&rawMode, length: MemoryLayout<UInt32>.stride, index: 11)
            }
            if let mask = draw.mask {
                var maskUniforms = mask.uniforms
                encoder.setFragmentBytes(&maskUniforms, length: MemoryLayout<MetalMaskUniforms>.stride, index: 7)
                encoder.setFragmentBuffer(mask.mesh.nodes, offset: 0, index: 8)
                encoder.setFragmentBuffer(mask.mesh.triangles, offset: 0, index: 9)
                encoder.setFragmentBuffer(mask.mesh.buffer, offset: 0, index: 10)
            }
            if let parent = draw.parentMask {
                var parentUniforms = parent.uniforms
                encoder.setFragmentBytes(&parentUniforms, length: MemoryLayout<MetalMaskUniforms>.stride, index: 12)
                encoder.setFragmentBuffer(parent.mesh.nodes, offset: 0, index: 13)
                encoder.setFragmentBuffer(parent.mesh.triangles, offset: 0, index: 14)
                encoder.setFragmentBuffer(parent.mesh.buffer, offset: 0, index: 15)
            }
            if var gradient = draw.gradient {
                encoder.setFragmentBytes(&gradient, length: MemoryLayout<MetalGradientUniforms>.stride, index: 6)
                encoder.setFragmentTexture(draw.texture, index: 0)
                encoder.setFragmentTexture(nil, index: 1)
            } else if let video = draw.video {
                var sampling = video.uniforms
                encoder.setFragmentBytes(&sampling, length: MemoryLayout<MetalVideoUniforms>.stride, index: 6)
                encoder.setFragmentTexture(video.luma, index: 0)
                encoder.setFragmentTexture(video.chroma, index: 1)
            } else {
                encoder.setFragmentTexture(draw.texture, index: 0)
                encoder.setFragmentTexture(draw.featherMaskTexture, index: 1)
            }
            if var tile = draw.motionTile {
                encoder.setFragmentBytes(&tile, length: MemoryLayout<MetalMotionTileUniforms>.stride, index: 6)
            }
            if var bulge = draw.bulge {
                encoder.setFragmentBytes(&bulge, length: MemoryLayout<MetalBulgeUniforms>.stride, index: 6)
            }
            if var corner = draw.cornerPin {
                encoder.setFragmentBytes(&corner, length: MemoryLayout<MetalCornerPinUniforms>.stride, index: 11)
            }
            if var map = draw.textBulgeMap {
                encoder.setFragmentBytes(&map, length: MemoryLayout<MetalTextBulgeMap>.stride, index: 11)
            }
            if var blur = draw.motionBlur {
                encoder.setFragmentBytes(&blur, length: MemoryLayout<MetalMotionBlurUniforms>.stride, index: 16)
            }
            // 一个包围矩形只生成一次片元覆盖；内部三角形由片元累积后统一SrcOver。
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }
}

/// 首帧局部pass和未完成纹理的成对保活，GPU结束前不得放入共享LRU。
struct MetalPictureWork {
    /// 活动纹理借用，完成后按请求代数决定发布或丢弃。
    let lease: MetalPictureLease
    /// 只绘制Shape或Text内容的局部批次，最终附件是lease纹理。
    let batch: MetalFrameBatch
}

/// 一次基础绘制及其保活资源，不遵循Sendable，不进入FramePlan或UI域。
struct MetalDraw {
    /// 不可变GPU顶点和保活的CPU身份。
    let mesh: MetalMesh
    /// 当前实际DrawOp独立消费的普通路径裁剪；nil表示无曲线路径限制。
    let mask: MetalMaskInput?
    /// 图片、局部组或渐变小LUT输入；与gradient同在只允许纹理渐变分支。
    let texture: (any MTLTexture)?
    /// 羽化alpha或轨道源的同尺寸局部图；只有已组合的内容图可以携带它。
    let featherMaskTexture: (any MTLTexture)?
    /// 视频的完整双平面输入及CV包装；nil表示不是视频，与texture互斥。
    let video: MetalVideoInput?
    /// 有界渐变常量；解析时与texture互斥，纹理分支需同时带小LUT。
    let gradient: MetalGradientUniforms?
    /// MotionTile直接对输入图片进行平铺采样；其它材料不携带它。
    let motionTile: MetalMotionTileUniforms?
    /// Image层tag59直接反采样原纹理；其它材料不携带此常量。
    let bulge: MetalBulgeUniforms?
    /// Image层tag58的四角逆映射；两个已知顺序可与其前后效果融合。
    let cornerPin: MetalCornerPinUniforms?
    /// Text Bulge的完整输入域到紧致附件UV映射。
    let textBulgeMap: MetalTextBulgeMap?
    /// 图像双层普通mask的外层覆盖，只有双mask材质读取。
    let parentMask: MetalMaskInput?
    /// 已经准备好的112字节绘制常量，包含当前pass像素原点和覆盖查询变换。
    let uniforms: MetalDrawUniforms
    /// 此绘制的真实裁剪来源，便于核对组作用域；实际GPU边界在batch.clipBuffer内。
    let clips: MetalClipValues
    /// 存在时第二纹理作为源图形颜色读入，并在片元中按alpha/luma与反向语义选出遮罩。
    let trackMatteMode: SourceTrackMatteType?
    /// 投影取源纹理alpha与当前预乘颜色，不使用源纹理RGB。
    let isShadow: Bool
    /// 仅整层Screen组最终绘回时选择固定混合系数。
    let screenBlend: Bool
    /// tag57精确静态参数只让绿色与alpha进入Screen混合。
    let levelsGreenOnly: Bool
    /// tag63效果后37次采样常量；nil表示普通Screen结果。
    let motionBlur: MetalMotionBlurUniforms?
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
