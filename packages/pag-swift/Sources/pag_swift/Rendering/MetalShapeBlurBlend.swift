import Metal

/// Shape源图在图层局部坐标经Gaussian后交给根pass混合；附件只覆盖内容紧界及模糊halo。
struct MetalShapeBlurBlendWork {
    /// 未乘图层整体alpha的Shape内容局部批次。
    let content: MetalFrameBatch
    /// 完整源内容的有界附件。
    let source: MetalGroupAttachment
    /// 复用已验证的缩采、两轴Gaussian与Decal边缘工作。
    let blur: MetalFastBlurWork

    /// 将子图元与必要局部效果计入帧绘制统计。
    var drawCount: Int {
        content.drawCount + 2 + (blur.layout.x.kernel == nil ? 0 : 1)
            + (blur.layout.y.kernel == nil ? 0 : 1)
    }

    /// GPU结束或准备失败时释放子批次；效果附件由根批次统一归还。
    func releaseTransients() { content.releaseTransients() }

    /// 先将整层Shape绘入局部源图，再执行FastBlur；最终HardLight由根颜色pass读取背景。
    func encode(commandBuffer: any MTLCommandBuffer, pipelines: MetalPipelines) throws {
        try content.encodePicture(to: source.texture, commandBuffer: commandBuffer)
        try blur.encode(commandBuffer: commandBuffer, pipelines: pipelines)
    }
}

/// 在取得drawable前固定Shape滤镜局部坐标、尺寸和全部附件所有权。
enum MetalShapeBlurBlendPreparation {
    /// 对唯一真实Shape FastBlur→HardLight子范围准备GPU工作；不可见时不分配附件。
    static func prepare(_ effect: FrameShapeBlurBlend, commands: ArraySlice<FrameCommand>,
                        frame: PreparedFrame, resources: MetalResources,
                        budget: inout MetalFrameBudget, visible: RenderBounds?) throws ->
        (work: MetalShapeBlurBlendWork, loans: [MetalGroupAttachment], toDisplay: SceneAffine)? {
        var trial = budget
        guard let bounds = try FeatherMaskContentBounds.measure(commands, frame: frame,
            layerMatrix: effect.matrix, resources: resources, budget: &trial),
            let visible else {
            budget = trial
            return nil
        }
        guard effect.blur.blurriness.isFinite, effect.blur.blurriness >= 0,
              effect.blur.direction == 0, !effect.blur.repeatEdgePixels,
              effect.opacity.isFinite, (0...1).contains(effect.opacity) else {
            throw PAGError.unsupportedFeature("shapeFastBlurParameters")
        }
        // 上游GetContentScale取显示矩阵最大轴尺度，并按1/20吸附以避免动画抖动。
        let scaleX = hypot(effect.matrix.a, effect.matrix.b)
        let scaleY = hypot(effect.matrix.c, effect.matrix.d)
        let scale = ceil(max(scaleX, scaleY) * 20) / 20
        guard scale.isFinite, scale > 0, scale <= 4096 else {
            throw PAGError.resourceLimitExceeded("shapeFastBlurScale")
        }
        let rounded = try RenderBounds(left: floor(bounds.left), top: floor(bounds.top),
            right: ceil(bounds.right), bottom: ceil(bounds.bottom))
        let scaleMatrix = try SceneAffine.scale(x: scale, y: scale)
        let scaled = try rounded.transformed(by: scaleMatrix)
        guard let rect = try scaled.exactPixelRect(clippedTo: scaled) else {
            budget = trial
            return nil
        }
        let sampling = try FastBlurSampling(effect.blur, effectScaleX: 1,
            effectScaleY: 1, sourceScale: Float(scale))
        let layout = try FastBlurTextureLayout(sampling, width: rect.width, height: rect.height)
        let outputX = rect.x.addingReportingOverflow(layout.x.outputLeft)
        let outputY = rect.y.addingReportingOverflow(layout.y.outputLeft)
        let outputRight = outputX.partialValue.addingReportingOverflow(layout.x.outputLength)
        let outputBottom = outputY.partialValue.addingReportingOverflow(layout.y.outputLength)
        guard !outputX.overflow, !outputY.overflow,
              !outputRight.overflow, !outputBottom.overflow else {
            throw PAGError.resourceLimitExceeded("shapeFastBlurDimensions")
        }
        let outputLocal = try RenderBounds(left: Double(outputX.partialValue) / scale,
            top: Double(outputY.partialValue) / scale,
            right: Double(outputRight.partialValue) / scale,
            bottom: Double(outputBottom.partialValue) / scale)
        guard try outputLocal.transformed(by: effect.matrix).intersection(visible) != nil else {
            budget = trial
            return nil
        }
        let cost = commands.count.multipliedReportingOverflow(by: 64)
        guard !cost.overflow else { throw PAGError.resourceLimitExceeded("maximumMetalFrameBytes") }
        try trial.reserve(cost.partialValue)
        try trial.reserve(256)
        let inverse = try effect.matrix.inverted()
        let shift = try SceneAffine.translation(x: -Double(rect.x), y: -Double(rect.y))
        let toSource = try scaleMatrix.following(shift)
        let localized = try commands.map {
            try FeatherMaskEffectPreparation.localized($0, inverse: inverse, texture: toSource)
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
        /// 每张局部纹理入账后立即登记，后续失败才能按已借顺序完整归还。
        func borrow(_ width: Int, _ height: Int) throws -> MetalGroupAttachment {
            let loan = try resources.groups.acquire(width: width, height: height, budget: &trial)
            loans.append(loan)
            return loan
        }
        let source = try borrow(rect.width, rect.height)
        content = try MetalFramePreparation.prepare(local, width: rect.width, height: rect.height,
            resources: resources, budget: &trial, disablePictureCache: true)
        let reduced = try borrow(layout.x.reducedLength, layout.y.reducedLength)
        let horizontal = try layout.x.kernel == nil ? nil : borrow(layout.x.reducedLength, layout.y.reducedLength)
        let vertical = try layout.y.kernel == nil ? nil : borrow(layout.x.reducedLength, layout.y.reducedLength)
        let output = try borrow(layout.x.outputLength, layout.y.outputLength)
        let blur = MetalFastBlurWork(source: source.texture, reduced: reduced.texture,
            horizontal: horizontal?.texture, vertical: vertical?.texture, output: output.texture,
            layout: layout, repeatEdgePixels: effect.blur.repeatEdgePixels)
        let outputMatrix = try SceneAffine.scale(x: Double(layout.x.outputLength),
            y: Double(layout.y.outputLength))
            .following(.translation(x: Double(outputX.partialValue), y: Double(outputY.partialValue)))
            .following(.scale(x: 1 / scale, y: 1 / scale)).following(effect.matrix)
        let work = MetalShapeBlurBlendWork(content: content!, source: source, blur: blur)
        budget = trial
        committed = true
        return (work, loans, outputMatrix)
    }
}
