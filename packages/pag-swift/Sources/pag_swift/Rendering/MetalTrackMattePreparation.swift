import Metal

/// 两段图形在同一有界局部像素范围的GPU工作；根帧只持有结果纹理到drawable的绘制。
struct MetalTrackMatteWork {
    /// 拥有者内容在应用轨道遮罩前的独立批次。
    let content: MetalFrameBatch
    /// 邻层源按自身时间、变换和透明度绘制的独立批次。
    let source: MetalFrameBatch
    /// 内容批次的局部颜色目标，顶层批次统一归还。
    let contentLoan: MetalGroupAttachment
    /// 源批次的局部颜色目标，顶层批次统一归还。
    let sourceLoan: MetalGroupAttachment

    /// 效果实际准备的图元数，供内部成本诊断统计。
    var drawCount: Int { content.drawCount + source.drawCount }

    /// 内容与源子批次的暂借资源在GPU结束或提交前失败后归还。
    func releaseTransients() {
        content.releaseTransients()
        source.releaseTransients()
    }

    /// 先画两段局部图形，根pass随后才可采样同一command buffer内的结果。
    func encode(commandBuffer: any MTLCommandBuffer) throws {
        try content.encodePicture(to: contentLoan.texture, commandBuffer: commandBuffer)
        try source.encodePicture(to: sourceLoan.texture, commandBuffer: commandBuffer)
    }
}

/// 可提交给根构建器的完整轨道遮罩局部结果，不代表整帧导出表面。
struct MetalTrackMattePrepared {
    /// 两段先行编码工作及其内部资源保活。
    let work: MetalTrackMatteWork
    /// 两张当前帧独占的局部附件，失败或GPU完成后归还。
    let loans: [MetalGroupAttachment]
    /// 单位内容纹理矩形到最终显示像素的映射。
    let toDisplay: SceneAffine
}

/// 按内容与遮罩源的真实范围准备局部Metal效果；不读取像素回CPU。
enum MetalTrackMattePreparation {
    /// 为已配对的源/拥有者命令准备局部帧；空正向交集返回nil，取消不泄露借用。
    static func prepare(_ matte: FrameTrackMatte, source: ArraySlice<FrameCommand>,
                        content: ArraySlice<FrameCommand>, frame: PreparedFrame,
                        resources: MetalResources, budget: inout MetalFrameBudget,
                        visible: RenderBounds?) throws -> MetalTrackMattePrepared? {
        guard matte.mode != .none else { throw PAGError.renderingFailure("metalTrackMatteMode") }
        var trial = budget
        let ownerBounds = try FeatherMaskContentBounds.measure(content, frame: frame,
            layerMatrix: .identity, resources: resources, budget: &trial,
            allowDropShadow: true, allowTrackMatte: true, allowConservativeMasks: true)
        let sourceBounds = try FeatherMaskContentBounds.measure(source, frame: frame,
            layerMatrix: .identity, resources: resources, budget: &trial,
            allowDropShadow: true, allowTrackMatte: true, allowConservativeMasks: true)
        guard let ownerBounds, let visible else {
            budget = trial
            return nil
        }
        let effectBounds: RenderBounds
        switch matte.mode {
        case .alpha, .luma:
            guard let sourceBounds, let intersection = ownerBounds.intersection(sourceBounds) else {
                budget = trial
                return nil
            }
            effectBounds = intersection
        case .alphaInverted, .lumaInverted:
            // 反向源范围之外的采样值为零，拥有者仍可见，不能只取正向交集。
            effectBounds = ownerBounds
        case .none:
            throw PAGError.renderingFailure("metalTrackMatteMode")
        }
        guard let rect = try effectBounds.pixelRect(clippedTo: visible) else {
            budget = trial
            return nil
        }
        let sourceFrame = try localFrame(source, from: frame, rect: rect, budget: &trial)
        let contentFrame = try localFrame(content, from: frame, rect: rect, budget: &trial)
        var loans: [MetalGroupAttachment] = []
        var batches: [MetalFrameBatch] = []
        var committed = false
        defer {
            // 任一子批次或第二次借用失败，必须连同第一次借用一起归还。
            if !committed {
                for batch in batches { batch.releaseTransients() }
                for loan in loans { resources.groups.release(loan) }
            }
        }
        _ = try resources.pipelines()
        let contentLoan = try resources.groups.acquire(width: rect.width, height: rect.height, budget: &trial)
        loans.append(contentLoan)
        let contentBatch = try MetalFramePreparation.prepare(contentFrame, width: rect.width,
            height: rect.height, resources: resources, budget: &trial, disablePictureCache: true)
        batches.append(contentBatch)
        let sourceLoan = try resources.groups.acquire(width: rect.width, height: rect.height, budget: &trial)
        loans.append(sourceLoan)
        let sourceBatch = try MetalFramePreparation.prepare(sourceFrame, width: rect.width,
            height: rect.height, resources: resources, budget: &trial, disablePictureCache: true)
        batches.append(sourceBatch)
        let toDisplay = try SceneAffine.scale(x: Double(rect.width), y: Double(rect.height))
            .following(.translation(x: Double(rect.x), y: Double(rect.y)))
        budget = trial
        committed = true
        return MetalTrackMattePrepared(work: MetalTrackMatteWork(content: contentBatch,
            source: sourceBatch, contentLoan: contentLoan, sourceLoan: sourceLoan),
            loans: loans, toDisplay: toDisplay)
    }

    /// 只重映命令矩阵到当前局部像素，不复制输入像素或改变资源身份。
    private static func localFrame(_ commands: ArraySlice<FrameCommand>, from frame: PreparedFrame,
                                   rect: RenderPixelRect, budget: inout MetalFrameBudget) throws -> PreparedFrame {
        let cost = commands.count.multipliedReportingOverflow(by: 64)
        guard !cost.overflow else { throw PAGError.resourceLimitExceeded("maximumMetalFrameBytes") }
        try budget.reserve(cost.partialValue + 256)
        let translation = try SceneAffine.translation(x: -Double(rect.x), y: -Double(rect.y))
        let local = try commands.map { try FeatherMaskEffectPreparation.localized($0,
            inverse: .identity, texture: translation) }
        let plan = FramePlan(time: frame.plan.time,
            targetBounds: DisplayRect(x: 0, y: 0, width: Double(rect.width), height: Double(rect.height)),
            commands: local)
        return PreparedFrame(plan: plan, images: frame.images, shapes: frame.shapes,
                             texts: frame.texts, videos: frame.videos)
    }
}
