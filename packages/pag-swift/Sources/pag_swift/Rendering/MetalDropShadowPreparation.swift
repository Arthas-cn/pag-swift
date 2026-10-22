import Metal

/// 一条样式的局部效果分支，先用纯值布局确定范围再借GPU附件。
private enum DropShadowStyleLayout {
    /// spread零且尺寸零，直接使用源alpha与源矩形。
    case offset
    /// spread零且尺寸正，使用两轴Gaussian及其透明halo。
    case gaussian(FeatherGaussianLayout)
    /// spread一，按SolidStroke椭圆样本扩散，包括尺寸零的二值中心采样。
    case stroke(DropShadowStrokeLayout, ScenePoint)
    /// V2中间份额先扩散，再在扩散后的局部附件执行Gaussian。
    case strokeGaussian(DropShadowStrokeLayout, ScenePoint, FeatherGaussianLayout?)

    /// 对源图外扩的左右/上下整数透明边距。
    var halo: (x: Int, y: Int) {
        switch self {
        case .offset: (0, 0)
        case .gaussian(let layout): (layout.haloX, layout.haloY)
        case .stroke(let layout, _): (layout.haloX, layout.haloY)
        case .strokeGaussian(let stroke, _, let blur):
            (stroke.haloX + (blur?.haloX ?? 0), stroke.haloY + (blur?.haloY ?? 0))
        }
    }
}

/// 一条样式对局部源alpha的可选Gaussian或扩散工作及其显示矩形。
struct MetalDropShadowStyleWork {
    /// 正尺寸时先对源做有界降采样；小sigma和零尺寸不需要。
    let downsample: MetalFeatherResamplePass?
    /// 水平后垂直的源核卷积；纯位移时为空。
    let blurPasses: [MetalFeatherBlurPass]
    /// 大sigma从卷积局部纹理回到原尺寸的有界重采样。
    let upsample: MetalFeatherResamplePass?
    /// 扩散椭圆采样；中间份额时它必须先于Gaussian编码。
    let stroke: MetalDropShadowStrokePass?
    /// 用于根pass读取alpha的纹理；GPU完成前由所属附件保活。
    let texture: any MTLTexture
    /// 单位纹理矩形在显示像素中的位置，尚未加样式位移。
    let toDisplay: SceneAffine
}

/// 一层投影在GPU编码前准备的局部内容与逐样式纹理；根pass按编码顺序读取。
struct MetalDropShadowWork {
    /// 不含本层整体alpha的原始图层绘制批次。
    let content: MetalFrameBatch
    /// 内容的有界颜色附件，由根批次统一归还。
    let contentLoan: MetalGroupAttachment
    /// 每条样式的可选卷积/扩散依编码顺序运行；spread零且尺寸零直接引用contentLoan。
    let styles: [MetalDropShadowStyleWork]
    /// 复用羽化的局部Gaussian及投影扩散GPU管线，不改变mask合成语义。
    let pipelines: MetalPipelines

    /// 效果实际需要的局部图元数，供内部预算诊断统计。
    var drawCount: Int {
        content.drawCount + styles.reduce(0) {
            $0 + ($1.downsample == nil ? 0 : 1) + $1.blurPasses.count
                + ($1.upsample == nil ? 0 : 1) + ($1.stroke == nil ? 0 : 1)
        }
    }

    /// GPU完成或提交前失败时释放子批次内部借用；本层附件由根批次释放。
    func releaseTransients() { content.releaseTransients() }

    /// 先把完整图层内容组合成有界纹理，再允许根pass按alpha重着色投影。
    func encode(commandBuffer: any MTLCommandBuffer) throws {
        try content.encodePicture(to: contentLoan.texture, commandBuffer: commandBuffer)
        for style in styles {
            // ComposeImageFilter先执行内部SolidStroke，再让外部Gaussian读取其完整halo。
            try style.stroke?.encode(commandBuffer: commandBuffer, pipeline: pipelines.shadowStroke)
            try style.downsample?.encode(commandBuffer: commandBuffer, pipeline: pipelines.featherResample)
            for pass in style.blurPasses {
                try pass.encode(commandBuffer: commandBuffer, pipeline: pipelines.featherBlur)
            }
            try style.upsample?.encode(commandBuffer: commandBuffer, pipeline: pipelines.featherResample)
        }
    }
}

/// 已完成尺寸、预算和子批次校验的投影输入，不是整帧离屏输出。
struct MetalDropShadowPrepared {
    /// 负责先于根pass生成局部内容的编码工作。
    let work: MetalDropShadowWork
    /// 成功后由根批次接管的附件借用。
    let loans: [MetalGroupAttachment]
    /// 单位内容纹理矩形到最终显示像素的矩阵。
    let toDisplay: SceneAffine
}

/// 静态投影在有界内容附件上准备位移、Gaussian、扩散及二者的有序组合。
enum MetalDropShadowPreparation {
    /// 测量源内容并建立局部GPU批次；不可见或全空内容返回nil，失败不泄露借用。
    static func prepare(_ shadow: FrameDropShadow, commands: ArraySlice<FrameCommand>,
                        frame: PreparedFrame, resources: MetalResources,
                        budget: inout MetalFrameBudget, visible: RenderBounds?) throws -> MetalDropShadowPrepared? {
        guard !shadow.styles.isEmpty else { throw PAGError.renderingFailure("emptyDropShadow") }
        guard shadow.styles.allSatisfy({ $0.spread.isFinite && (0...1).contains($0.spread) }) else {
            throw PAGError.unsupportedFeature("dropShadowSpread")
        }
        guard shadow.styles.allSatisfy({ $0.size.isFinite && $0.size >= 0 }) else {
            throw PAGError.unsupportedFeature("dropShadowNegativeSize")
        }
        var trial = budget
        guard let bounds = try FeatherMaskContentBounds.measure(commands, frame: frame,
            layerMatrix: .identity, resources: resources, budget: &trial,
            allowDropShadow: true, allowTrackMatte: true, allowTextBulge: true), let visible else {
            budget = trial
            return nil
        }
        guard let rect = try bounds.pixelRect(clippedTo: bounds) else {
            budget = trial
            return nil
        }
        let layouts = try shadow.styles.map { style -> DropShadowStyleLayout in
            if style.spread == 1 {
                let size = try DropShadowOffset.displaySpreadSize(style: style, shadow: shadow)
                return .stroke(try DropShadowStrokeLayout.make(size: size,
                    width: rect.width, height: rect.height), size)
            }
            if style.spread > 0 {
                let size = try DropShadowOffset.displayEffectSize(style: style, shadow: shadow)
                let spread = ScenePoint(x: size.x * style.spread, y: size.y * style.spread)
                let stroke = try DropShadowStrokeLayout.make(size: spread,
                    width: rect.width, height: rect.height)
                let remaining = ScenePoint(x: size.x * (1 - style.spread),
                                           y: size.y * (1 - style.spread))
                let blur = try FeatherGaussianLayout.make(remaining,
                    width: stroke.width, height: stroke.height)
                return .strokeGaussian(stroke, spread, blur)
            }
            guard style.size > 0 else { return .offset }
            let size = try DropShadowOffset.displayBlurSize(style: style, shadow: shadow)
            guard let blur = try FeatherGaussianLayout.make(size, width: rect.width,
                height: rect.height) else { return .offset }
            return .gaussian(blur)
        }
        // 源内容可在目标外，却凭投影位移进入可见区；先判范围再借局部附件。
        let hasVisibleShadow = try zip(shadow.styles, layouts).contains { style, layout in
            let offset = try DropShadowOffset.display(style: style, shadow: shadow)
            let haloX = Double(layout.halo.x), haloY = Double(layout.halo.y)
            let spread = try RenderBounds(left: bounds.left - haloX, top: bounds.top - haloY,
                right: bounds.right + haloX, bottom: bounds.bottom + haloY)
            let shifted = try spread.transformed(by: .translation(x: offset.x, y: offset.y))
            return shifted.intersection(visible) != nil
        }
        guard hasVisibleShadow || bounds.intersection(visible) != nil else {
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
        let loan = try resources.groups.acquire(width: rect.width, height: rect.height, budget: &trial)
        loans.append(loan)
        content = try MetalFramePreparation.prepare(local, width: rect.width, height: rect.height,
            resources: resources, budget: &trial, disablePictureCache: true)
        let toDisplay = try SceneAffine.scale(x: Double(rect.width), y: Double(rect.height))
            .following(.translation(x: Double(rect.x), y: Double(rect.y)))
        var styleWorks: [MetalDropShadowStyleWork] = []
        for (style, layout) in zip(shadow.styles, layouts) {
            try Task.checkCancellation()
            switch layout {
            case .offset:
                styleWorks.append(MetalDropShadowStyleWork(downsample: nil, blurPasses: [],
                    upsample: nil, stroke: nil, texture: loan.texture, toDisplay: toDisplay))
            case .gaussian(let blur):
                let result = try prepareBlur(blur, source: loan.texture, rect: rect,
                    resources: resources, budget: &trial, loans: &loans)
                styleWorks.append(result)
            case .stroke(let stroke, let size):
                let origin = try strokeOrigin(rect: rect, stroke: stroke)
                let destination = try resources.groups.acquire(width: stroke.width,
                    height: stroke.height, budget: &trial)
                loans.append(destination)
                let pass = MetalDropShadowStrokePass(source: loan.texture, destination: destination,
                    size: size, thick: style.size >= 12, haloX: stroke.haloX, haloY: stroke.haloY)
                let matrix = try SceneAffine.scale(x: Double(stroke.width), y: Double(stroke.height))
                    .following(.translation(x: Double(origin.x), y: Double(origin.y)))
                styleWorks.append(MetalDropShadowStyleWork(downsample: nil, blurPasses: [],
                    upsample: nil, stroke: pass, texture: destination.texture, toDisplay: matrix))
            case .strokeGaussian(let stroke, let size, let blur):
                let origin = try strokeOrigin(rect: rect, stroke: stroke)
                let destination = try resources.groups.acquire(width: stroke.width,
                    height: stroke.height, budget: &trial)
                loans.append(destination)
                let pass = MetalDropShadowStrokePass(source: loan.texture, destination: destination,
                    size: size, thick: style.size * style.spread >= 12,
                    haloX: stroke.haloX, haloY: stroke.haloY)
                let strokeRect = RenderPixelRect(x: origin.x, y: origin.y,
                    width: stroke.width, height: stroke.height)
                if let blur {
                    let result = try prepareBlur(blur, source: destination.texture, rect: strokeRect,
                        resources: resources, budget: &trial, loans: &loans)
                    styleWorks.append(MetalDropShadowStyleWork(downsample: result.downsample,
                        blurPasses: result.blurPasses, upsample: result.upsample,
                        stroke: pass, texture: result.texture, toDisplay: result.toDisplay))
                } else {
                    let matrix = try SceneAffine.scale(x: Double(stroke.width), y: Double(stroke.height))
                        .following(.translation(x: Double(strokeRect.x), y: Double(strokeRect.y)))
                    styleWorks.append(MetalDropShadowStyleWork(downsample: nil, blurPasses: [],
                        upsample: nil, stroke: pass, texture: destination.texture, toDisplay: matrix))
                }
            }
        }
        guard let content else { throw PAGError.renderingFailure("dropShadowContentBatch") }
        let work = MetalDropShadowWork(content: content, contentLoan: loan,
            styles: styleWorks, pipelines: pipelines)
        budget = trial
        committed = true
        return MetalDropShadowPrepared(work: work, loans: loans, toDisplay: toDisplay)
    }

    /// 将扩散halo从源整数起点扣除；恶意极值不能触发Swift整数溢出陷阱。
    private static func strokeOrigin(rect: RenderPixelRect,
                                     stroke: DropShadowStrokeLayout) throws -> (x: Int, y: Int) {
        let x = rect.x.subtractingReportingOverflow(stroke.haloX)
        let y = rect.y.subtractingReportingOverflow(stroke.haloY)
        guard !x.overflow, !y.overflow else {
            throw PAGError.resourceLimitExceeded("dropShadowStrokeDimensions")
        }
        return (x.partialValue, y.partialValue)
    }

    /// 每条正尺寸样式独立借有界卷积附件；失败由prepare外层统一归还全部借用。
    private static func prepareBlur(_ layout: FeatherGaussianLayout, source: any MTLTexture,
                                    rect: RenderPixelRect, resources: MetalResources,
                                    budget: inout MetalFrameBudget,
                                    loans: inout [MetalGroupAttachment]) throws -> MetalDropShadowStyleWork {
        var texture = source
        let convolutionWidth = layout.reduction?.width ?? layout.width
        let convolutionHeight = layout.reduction?.height ?? layout.height
        var downsample: MetalFeatherResamplePass?
        var passes: [MetalFeatherBlurPass] = []
        var upsample: MetalFeatherResamplePass?
        if let reduction = layout.reduction {
            let destination = try resources.groups.acquire(width: reduction.width,
                height: reduction.height, budget: &budget)
            loans.append(destination)
            downsample = try MetalFeatherResamplePass(source: texture, destination: destination,
                transform: SIMD4(1 / reduction.scaleX, 1 / reduction.scaleY,
                                 Float(reduction.sampleLeft), Float(reduction.sampleTop)))
            texture = destination.texture
        }
        if let horizontal = layout.horizontal {
            let destination = try resources.groups.acquire(width: convolutionWidth,
                height: convolutionHeight, budget: &budget)
            loans.append(destination)
            passes.append(MetalFeatherBlurPass(source: texture, destination: destination,
                axis: horizontal, horizontal: true,
                shiftX: layout.reduction == nil ? layout.haloX : 0,
                shiftY: layout.reduction == nil ? layout.haloY : 0))
            texture = destination.texture
        }
        if let vertical = layout.vertical {
            let destination = try resources.groups.acquire(width: convolutionWidth,
                height: convolutionHeight, budget: &budget)
            loans.append(destination)
            passes.append(MetalFeatherBlurPass(source: texture, destination: destination,
                axis: vertical, horizontal: false,
                shiftX: layout.reduction == nil && layout.horizontal == nil ? layout.haloX : 0,
                shiftY: layout.reduction == nil && layout.horizontal == nil ? layout.haloY : 0))
            texture = destination.texture
        }
        if let reduction = layout.reduction {
            // 输出仍覆盖源尺寸与透明halo；样本裁剪和真实比例由布局提前固定。
            let destination = try resources.groups.acquire(width: layout.width,
                height: layout.height, budget: &budget)
            loans.append(destination)
            upsample = try MetalFeatherResamplePass(source: texture, destination: destination,
                transform: SIMD4(reduction.scaleX, reduction.scaleY,
                                 Float(-layout.haloX - reduction.sampleLeft) * reduction.scaleX,
                                 Float(-layout.haloY - reduction.sampleTop) * reduction.scaleY))
            texture = destination.texture
        }
        let toDisplay = try SceneAffine.scale(x: Double(layout.width), y: Double(layout.height))
            .following(.translation(x: Double(rect.x - layout.haloX), y: Double(rect.y - layout.haloY)))
        return MetalDropShadowStyleWork(downsample: downsample, blurPasses: passes,
            upsample: upsample, stroke: nil, texture: texture, toDisplay: toDisplay)
    }
}
