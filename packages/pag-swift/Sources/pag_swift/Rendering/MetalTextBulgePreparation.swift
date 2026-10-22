import Metal

/// 完整合成单位坐标到紧致内容附件UV的两行仿射映射，供Text Bulge与预合成平铺共用。
struct MetalTextBulgeMap {
    /// 原滤镜输入单位x/y及常量项映到局部附件u。
    let horizontal: SIMD4<Float>
    /// 原滤镜输入单位x/y及常量项映到局部附件v。
    let vertical: SIMD4<Float>

    /// 以父合成完整尺寸建立映射，不能改用glyph附件尺寸归一Bulge参数。
    init(effect: FrameTextBulge, rect: RenderPixelRect) throws {
        try self.init(compositionSize: effect.compositionSize,
            compositionMatrix: effect.compositionMatrix, rect: rect)
    }

    /// 把完整合成域映到局部附件，附件尺寸只决定UV，不重新定义效果中心与范围。
    init(compositionSize: PAGSize, compositionMatrix: SceneAffine, rect: RenderPixelRect) throws {
        let origin = try compositionMatrix.applying(to: .zero)
        let right = try compositionMatrix.applying(to:
            ScenePoint(x: compositionSize.width, y: 0))
        let bottom = try compositionMatrix.applying(to:
            ScenePoint(x: 0, y: compositionSize.height))
        horizontal = SIMD4(Float((right.x - origin.x) / Double(rect.width)),
            Float((bottom.x - origin.x) / Double(rect.width)),
            Float((origin.x - Double(rect.x)) / Double(rect.width)), 0)
        vertical = SIMD4(Float((right.y - origin.y) / Double(rect.height)),
            Float((bottom.y - origin.y) / Double(rect.height)),
            Float((origin.y - Double(rect.y)) / Double(rect.height)), 0)
        guard (0..<4).allSatisfy({ horizontal[$0].isFinite && vertical[$0].isFinite }) else {
            throw PAGError.unsupportedFeature("textBulgeMapping")
        }
    }

    /// MotionBlur的完整内容域可能只是合成内一段有界区域，映射不能擅自改成合成全幅。
    init(effectBounds: RenderBounds, effectMatrix: SceneAffine,
         rect: RenderPixelRect) throws {
        let origin = try effectMatrix.applying(to:
            ScenePoint(x: effectBounds.left, y: effectBounds.top))
        let right = try effectMatrix.applying(to:
            ScenePoint(x: effectBounds.right, y: effectBounds.top))
        let bottom = try effectMatrix.applying(to:
            ScenePoint(x: effectBounds.left, y: effectBounds.bottom))
        horizontal = SIMD4(Float((right.x - origin.x) / Double(rect.width)),
            Float((bottom.x - origin.x) / Double(rect.width)),
            Float((origin.x - Double(rect.x)) / Double(rect.width)), 0)
        vertical = SIMD4(Float((right.y - origin.y) / Double(rect.height)),
            Float((bottom.y - origin.y) / Double(rect.height)),
            Float((origin.y - Double(rect.y)) / Double(rect.height)), 0)
        guard (0..<4).allSatisfy({ horizontal[$0].isFinite && vertical[$0].isFinite }) else {
            throw PAGError.unsupportedFeature("motionBlurMapping")
        }
    }
}

/// 当前Text层一次有界内容合成的GPU工作，结果由根pass直接采样并绘回drawable。
struct MetalTextBulgeWork {
    /// 不含图层整体alpha的字形与背景局部批次。
    let content: MetalFrameBatch
    /// 只覆盖可见字形/背景及透明采样halo的颜色附件。
    let loan: MetalGroupAttachment

    /// 内容实际产生的图元数，用于内部资源诊断。
    var drawCount: Int { content.drawCount }

    /// 子批次内部借用由它自己归还；本层loan由根批次统一归还。
    func releaseTransients() { content.releaseTransients() }

    /// 必须先于根pass绘制内容，且同一command buffer内随后才读取此纹理。
    func encode(commandBuffer: any MTLCommandBuffer) throws {
        try content.encodePicture(to: loan.texture, commandBuffer: commandBuffer)
    }
}

/// 文字内容局部附件、最终显示矩阵和反采样映射的原子准备结果。
struct MetalTextBulgePrepared {
    /// 根批次持有并先行编码的局部工作。
    let work: MetalTextBulgeWork
    /// 完整效果输出矩形到显示像素的矩阵。
    let toDisplay: SceneAffine
    /// 父合成输入域到紧致纹理的坐标映射。
    let map: MetalTextBulgeMap
}

/// 只借真实字形范围的局部纹理，保持上游Text Bulge的父合成完整输入坐标域。
enum MetalTextBulgePreparation {
    /// 测量、借用、重映文字命令并准备局部批次；空文字返回nil，失败归还所有借用。
    static func prepare(_ effect: FrameTextBulge, frame: PreparedFrame,
                        resources: MetalResources, budget: inout MetalFrameBudget) throws -> MetalTextBulgePrepared? {
        var trial = budget
        let clip = FrameClip(size: effect.compositionSize, matrix: effect.compositionMatrix)
        let group = FrameGroup(layerID: nil, frame: effect.frame, clip: clip, opacity: 1)
        var commands: [FrameCommand] = [.beginGroup(group)]
        if let background = effect.background { commands.append(.shape(background)) }
        commands += effect.passes.map(FrameCommand.text)
        commands.append(.endGroup)
        guard let bounds = try FeatherMaskContentBounds.measure(commands[...], frame: frame,
            layerMatrix: .identity, resources: resources, budget: &trial) else {
            budget = trial
            return nil
        }
        // 双线性滤波必须在有效字形外还有透明一像素，否则紧致纹理边界会被钳成实色。
        let expanded = try RenderBounds(left: bounds.left - 1, top: bounds.top - 1,
            right: bounds.right + 1, bottom: bounds.bottom + 1)
        guard let rect = try expanded.pixelRect(clippedTo: expanded) else {
            budget = trial
            return nil
        }
        let cost = commands.count.multipliedReportingOverflow(by: 64)
        guard !cost.overflow else { throw PAGError.resourceLimitExceeded("maximumMetalFrameBytes") }
        try trial.reserve(cost.partialValue + 256)
        let translation = try SceneAffine.translation(x: -Double(rect.x), y: -Double(rect.y))
        let localCommands = try commands.map {
            try FeatherMaskEffectPreparation.localized($0, inverse: .identity, texture: translation)
        }
        let plan = FramePlan(time: frame.plan.time,
            targetBounds: DisplayRect(x: 0, y: 0, width: Double(rect.width), height: Double(rect.height)),
            commands: localCommands)
        let local = PreparedFrame(plan: plan, images: frame.images, shapes: frame.shapes,
            texts: frame.texts, videos: frame.videos)
        let map = try MetalTextBulgeMap(effect: effect, rect: rect)
        let output = try SceneAffine.scale(
            x: effect.bulge.outputSize.width * effect.compositionSize.width,
            y: effect.bulge.outputSize.height * effect.compositionSize.height)
            .following(.translation(
                x: effect.bulge.outputOrigin.x * effect.compositionSize.width,
                y: effect.bulge.outputOrigin.y * effect.compositionSize.height))
            .following(effect.compositionMatrix)
        var loan: MetalGroupAttachment?
        var batch: MetalFrameBatch?
        var committed = false
        defer {
            if !committed {
                batch?.releaseTransients()
                if let loan { resources.groups.release(loan) }
            }
        }
        loan = try resources.groups.acquire(width: rect.width, height: rect.height, budget: &trial)
        batch = try MetalFramePreparation.prepare(local, width: rect.width, height: rect.height,
            resources: resources, budget: &trial, disablePictureCache: true)
        guard let loan, let batch else { throw PAGError.renderingFailure("textBulgeContentBatch") }
        budget = trial
        committed = true
        return MetalTextBulgePrepared(work: MetalTextBulgeWork(content: batch, loan: loan),
            toDisplay: output, map: map)
    }
}
