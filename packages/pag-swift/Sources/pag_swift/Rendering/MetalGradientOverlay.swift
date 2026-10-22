import Metal

/// Angle白黑样式的局部尺寸及逆旋转常量；四个Float与MSL共享布局。
private struct MetalGradientOverlayUniforms {
    /// 输入宽、高，以及上游逆样式矩阵的cos/sin。
    let sizeAndRotation: SIMD4<Float>
}

/// 一层Shape原图和其渐变叠加结果的有界GPU工作，最终颜色仍由根pass写drawable。
struct MetalGradientOverlayWork {
    /// 不含本层整体alpha的完整Shape内容批次。
    let content: MetalFrameBatch
    /// Shape内容局部附件；样式片元只从这里取整层合成的颜色和alpha。
    let source: MetalGroupAttachment
    /// 样式合成后的局部附件；根绘制按原图层顺序引用。
    let result: MetalGroupAttachment
    /// Angle样式片元管线，不读回CPU。
    let pipeline: any MTLRenderPipelineState
    /// 源宽高和逆样式旋转的GPU参数。
    let uniforms: SIMD4<Float>

    /// 图元统计包含内容和一次局部样式合成。
    var drawCount: Int { content.drawCount + 1 }

    /// GPU完成或准备失败时释放内容子批次暂存；两张附件由根批次统一归还。
    func releaseTransients() { content.releaseTransients() }

    /// 先合成整层源图，再按上游GradientOverlay的DstIn与Normal顺序写有界结果。
    func encode(commandBuffer: any MTLCommandBuffer) throws {
        try content.encodePicture(to: source.texture, commandBuffer: commandBuffer)
        let target = result.texture
        guard source.texture.pixelFormat == .bgra8Unorm, target.pixelFormat == .bgra8Unorm,
              source.texture.width == target.width, source.texture.height == target.height else {
            throw PAGError.renderingFailure("gradientOverlayDimensions")
        }
        let pass = MTLRenderPassDescriptor()
        guard let color = pass.colorAttachments[0] else {
            throw PAGError.renderingFailure("metalColorAttachment")
        }
        color.texture = target
        color.loadAction = .clear
        color.storeAction = .store
        color.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw PAGError.renderingFailure("metalRenderEncoder")
        }
        defer { encoder.endEncoding() }
        encoder.label = "pag.local.gradientOverlay"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
            width: Double(target.width), height: Double(target.height), znear: 0, zfar: 1))
        encoder.setCullMode(.none)
        encoder.setRenderPipelineState(pipeline)
        var bounds = SIMD4<Float>(-1, 1, 1, -1)
        var constants = MetalGradientOverlayUniforms(sizeAndRotation: uniforms)
        encoder.setVertexBytes(&bounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&constants,
            length: MemoryLayout<MetalGradientOverlayUniforms>.stride, index: 1)
        encoder.setFragmentTexture(source.texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}

/// 在完整Shape内容范围内准备两张局部纹理，不额外创建整帧输出或CPU像素副本。
enum MetalGradientOverlayPreparation {
    /// 测量、计费并准备内容/样式工作；无可见内容返回nil，失败时归还已借附件。
    static func prepare(_ overlay: FrameGradientOverlay, commands: ArraySlice<FrameCommand>,
                        frame: PreparedFrame, resources: MetalResources,
                        budget: inout MetalFrameBudget,
                        visible: RenderBounds?) throws -> (work: MetalGradientOverlayWork,
                            loans: [MetalGroupAttachment], toDisplay: SceneAffine)? {
        var trial = budget
        guard let bounds = try FeatherMaskContentBounds.measure(commands, frame: frame,
            layerMatrix: .identity, resources: resources, budget: &trial),
            let visible, bounds.intersection(visible) != nil else {
            budget = trial
            return nil
        }
        // 样式坐标以完整源图宽高归一；裁到drawable会使Angle中心随视口移动。
        guard let rect = try bounds.pixelRect(clippedTo: bounds) else {
            budget = trial
            return nil
        }
        guard overlay.angle.isFinite else { throw PAGError.renderingFailure("gradientOverlayAngle") }
        let radians = (360 - overlay.angle).truncatingRemainder(dividingBy: 360) * .pi / 180
        let cosine = Float(cos(radians)), sine = Float(sin(radians))
        guard cosine.isFinite, sine.isFinite else {
            throw PAGError.renderingFailure("gradientOverlayAngle")
        }
        let count = commands.count.multipliedReportingOverflow(by: 64)
        guard !count.overflow else { throw PAGError.resourceLimitExceeded("maximumMetalFrameBytes") }
        try trial.reserve(count.partialValue + 256)
        let translation = try SceneAffine.translation(x: -Double(rect.x), y: -Double(rect.y))
        let localized = try commands.map {
            try FeatherMaskEffectPreparation.localized($0, inverse: .identity, texture: translation)
        }
        let plan = FramePlan(time: frame.plan.time,
            targetBounds: DisplayRect(x: 0, y: 0,
                width: Double(rect.width), height: Double(rect.height)), commands: localized)
        let local = PreparedFrame(plan: plan, images: frame.images, shapes: frame.shapes,
            texts: frame.texts, videos: frame.videos)
        var loans: [MetalGroupAttachment] = []
        var content: MetalFrameBatch?
        var committed = false
        defer {
            if !committed {
                content?.releaseTransients()
                for loan in loans { resources.groups.release(loan) }
            }
        }
        let pipelines = try resources.pipelines()
        let source = try resources.groups.acquire(width: rect.width, height: rect.height, budget: &trial)
        loans.append(source)
        content = try MetalFramePreparation.prepare(local, width: rect.width, height: rect.height,
            resources: resources, budget: &trial, disablePictureCache: true)
        let result = try resources.groups.acquire(width: rect.width, height: rect.height, budget: &trial)
        loans.append(result)
        let toDisplay = try SceneAffine.scale(x: Double(rect.width), y: Double(rect.height))
            .following(.translation(x: Double(rect.x), y: Double(rect.y)))
        let work = MetalGradientOverlayWork(content: content!, source: source, result: result,
            pipeline: pipelines.gradientOverlay,
            uniforms: SIMD4(Float(rect.width), Float(rect.height), cosine, sine))
        budget = trial
        committed = true
        return (work, loans, toDisplay)
    }
}
