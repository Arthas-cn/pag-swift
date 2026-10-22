import Metal

/// 一个效果局部贴图到另一附件的预验证矩形绘制；不暴露离屏出图入口。
struct MetalFeatherCopy {
    /// 源图在GPU完成前由所属附件借用保活。
    let texture: any MTLTexture
    /// 对目标附件的NDC左上与右下，和MSL的16字节常量一一对应。
    let bounds: SIMD4<Float>

    /// 只接受效果源码所用的正向缩放/平移，不把旋转或负倍率误当轴对齐图片。
    init(texture: any MTLTexture, matrix: SceneAffine, targetWidth: Int, targetHeight: Int) throws {
        guard matrix.b == 0, matrix.c == 0, matrix.a > 0, matrix.d > 0,
              targetWidth > 0, targetHeight > 0 else {
            throw PAGError.renderingFailure("featherCopyTransform")
        }
        let far = try matrix.applying(to: ScenePoint(x: 1, y: 1))
        let left = 2 * matrix.tx / Double(targetWidth) - 1
        let top = 1 - 2 * matrix.ty / Double(targetHeight)
        let right = 2 * far.x / Double(targetWidth) - 1
        let bottom = 1 - 2 * far.y / Double(targetHeight)
        let packed = SIMD4(Float(left), Float(top), Float(right), Float(bottom))
        guard packed.x.isFinite, packed.y.isFinite, packed.z.isFinite, packed.w.isFinite else {
            throw PAGError.renderingFailure("featherCopyTransform")
        }
        self.texture = texture
        bounds = packed
    }
}

/// 一项alpha先在自身路径bounds附件合成，再作为默认SrcOver来源进入总体mask。
struct MetalFeatherItemWork {
    /// 普通路径覆盖与UInt8透明度的独立局部批次。
    let batch: MetalFrameBatch
    /// 对应项的局部alpha附件；由根批次统一归还。
    let loan: MetalGroupAttachment
    /// 大sigma先把扩出halo的源样本线性缩到有界卷积纹理。
    let downsample: MetalFeatherResamplePass?
    /// 可选两轴Gaussian的顺序pass；零/负feather没有额外附件。
    let blurPasses: [MetalFeatherBlurPass]
    /// 卷积结束后按上游实际比例线性回到原效果尺寸。
    let upsample: MetalFeatherResamplePass?
    /// 该项图像在总体mask中的回填位置。
    let copy: MetalFeatherCopy
}

/// 羽化层实际GPU编码次序；根pass最终仍直接画drawable。
struct MetalFeatherWork {
    /// 按原混合/透明度顺序形成一次的内容批次。
    let content: MetalFrameBatch
    /// 内容批次写入的局部附件，由根批次借用保活。
    let contentLoan: MetalGroupAttachment
    /// 逐项alpha批次和到总体mask的SrcOver矩形。
    let items: [MetalFeatherItemWork]
    /// 总体mask保留自身10%外扩尺寸，不按屏幕clip截掉源样本。
    let overallLoan: MetalGroupAttachment
    /// mask按内容矩阵映到与内容同尺寸的效果局部表面。
    let maskLoan: MetalGroupAttachment
    /// 总体mask到内容同尺寸mask附件的重采样矩形。
    let overallCopy: MetalFeatherCopy

    /// 含内容、单项、总体与共同mask表面的实际GPU绘制数。
    var drawCount: Int {
        content.drawCount + items.reduce(0) {
            $0 + $1.batch.drawCount + ($1.downsample == nil ? 0 : 1)
                + $1.blurPasses.count + ($1.upsample == nil ? 0 : 1) + 1
        } + 1
    }

    /// 只有GPU完成或准备整帧失败才归还子批次自身的临时组，顶层四类借用由根批次归还。
    func releaseTransients() {
        content.releaseTransients()
        for item in items { item.batch.releaseTransients() }
    }

    /// 内容和每项alpha先独立绘制；SrcOver累计总体mask后映入共同局部表面。
    func encode(commandBuffer: any MTLCommandBuffer, pipelines: MetalPipelines) throws {
        try content.encodePicture(to: contentLoan.texture, commandBuffer: commandBuffer)
        for item in items {
            try Task.checkCancellation()
            try item.batch.encodePicture(to: item.loan.texture, commandBuffer: commandBuffer)
            if let downsample = item.downsample {
                try downsample.encode(commandBuffer: commandBuffer, pipeline: pipelines.featherResample)
            }
            for pass in item.blurPasses {
                try pass.encode(commandBuffer: commandBuffer, pipeline: pipelines.featherBlur)
            }
            if let upsample = item.upsample {
                try upsample.encode(commandBuffer: commandBuffer, pipeline: pipelines.featherResample)
            }
        }
        try Self.copy(items.map(\.copy), to: overallLoan.texture,
                      commandBuffer: commandBuffer, pipeline: pipelines.featherCopy)
        try Self.copy([overallCopy], to: maskLoan.texture,
                      commandBuffer: commandBuffer, pipeline: pipelines.featherCopy)
    }

    /// 局部alpha附件每次clear后按源顺序执行SrcOver，空列表保持透明。
    private static func copy(_ draws: [MetalFeatherCopy], to texture: any MTLTexture,
                             commandBuffer: any MTLCommandBuffer,
                             pipeline: any MTLRenderPipelineState) throws {
        try Task.checkCancellation()
        guard texture.pixelFormat == .bgra8Unorm, texture.sampleCount == 1 else {
            throw PAGError.renderingFailure("featherPassDimensions")
        }
        let pass = MTLRenderPassDescriptor()
        guard let color = pass.colorAttachments[0] else { throw PAGError.renderingFailure("metalColorAttachment") }
        color.texture = texture
        color.loadAction = .clear
        color.storeAction = .store
        color.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw PAGError.renderingFailure("metalRenderEncoder")
        }
        defer { encoder.endEncoding() }
        encoder.label = "pag.local.feather.mask"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
            width: Double(texture.width), height: Double(texture.height), znear: 0, zfar: 1))
        encoder.setCullMode(.none)
        encoder.setRenderPipelineState(pipeline)
        for draw in draws {
            try Task.checkCancellation()
            var bounds = draw.bounds
            encoder.setVertexBytes(&bounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentTexture(draw.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }
}

/// 已成功准备的效果，根批次接管所有局部借用后才能发布最终draw。
struct MetalFeatherPrepared {
    /// 局部编码的依赖顺序及子批次保活。
    let work: MetalFeatherWork
    /// 内容、每项alpha、总体mask和共同mask附件的独占借用。
    let loans: [MetalGroupAttachment]
    /// 整层原始内容的组合结果，最终draw的纹理0。
    let contentTexture: any MTLTexture
    /// 与内容同尺寸的mask alpha，最终draw的纹理1。
    let maskTexture: any MTLTexture
    /// 单位内容纹理矩形到显示像素的矩阵。
    let contentToDisplay: SceneAffine
}

/// 只为真实羽化层分配有界局部Metal附件；大sigma样本先按可见clip裁剪。
enum MetalFeatherPreparation {
    /// 完成内容/alpha四段局部工作并原子移交借用；不可见内容仍先核对源合同。
    static func prepare(_ mask: FrameMask, commands: ArraySlice<FrameCommand>, frame: PreparedFrame,
                        resources: MetalResources, budget: inout MetalFrameBudget,
                        visible: Bool) throws -> MetalFeatherPrepared? {
        var trial = budget
        guard let effect = try FeatherMaskEffectPreparation.make(mask, commands: commands,
            frame: frame, resources: resources, budget: &trial) else {
            budget = trial
            return nil
        }
        let blurLayouts = try effect.items.map {
            try FeatherGaussianLayout.make($0.feather, width: $0.width, height: $0.height,
                clip: FeatherGaussianClip(originX: Float($0.toOverall.tx),
                                          originY: Float($0.toOverall.ty),
                                          width: effect.overallWidth, height: effect.overallHeight))
        }
        guard visible else {
            budget = trial
            return nil
        }
        var loans: [MetalGroupAttachment] = []
        var batches: [MetalFrameBatch] = []
        var committed = false
        defer {
            if !committed {
                for batch in batches { batch.releaseTransients() }
                for loan in loans { resources.groups.release(loan) }
            }
        }
        _ = try resources.pipelines()
        let contentLoan = try resources.groups.acquire(width: effect.layout.width,
            height: effect.layout.height, budget: &trial)
        loans.append(contentLoan)
        let content = try MetalFramePreparation.prepare(effect.content, width: effect.layout.width,
            height: effect.layout.height, resources: resources, budget: &trial,
            disablePictureCache: true)
        batches.append(content)
        var itemWorks: [MetalFeatherItemWork] = []
        for (item, blur) in zip(effect.items, blurLayouts) {
            try Task.checkCancellation()
            let loan = try resources.groups.acquire(width: item.width, height: item.height, budget: &trial)
            loans.append(loan)
            let batch = try MetalFramePreparation.prepare(item.frame, width: item.width,
                height: item.height, resources: resources, budget: &trial, disablePictureCache: true)
            batches.append(batch)
            var copyTexture = loan.texture
            var copyWidth = item.width, copyHeight = item.height
            var copyX = item.toOverall.tx, copyY = item.toOverall.ty
            var downsample: MetalFeatherResamplePass?
            var blurPasses: [MetalFeatherBlurPass] = []
            var upsample: MetalFeatherResamplePass?
            if let blur {
                let convolutionWidth = blur.reduction?.width ?? blur.width
                let convolutionHeight = blur.reduction?.height ?? blur.height
                if let reduction = blur.reduction {
                    // 上游先扩出源样本Rect，再线性缩入按roundOut取得的卷积纹理。
                    let destination = try resources.groups.acquire(width: reduction.width,
                        height: reduction.height, budget: &trial)
                    loans.append(destination)
                    downsample = try MetalFeatherResamplePass(source: copyTexture, destination: destination,
                        transform: SIMD4(1 / reduction.scaleX, 1 / reduction.scaleY,
                                         Float(reduction.sampleLeft), Float(reduction.sampleTop)))
                    copyTexture = destination.texture
                }
                // 第一轴包含全halo，第二轴对同尺寸中间图卷积；源外样本只能取透明。
                if let horizontal = blur.horizontal {
                    let destination = try resources.groups.acquire(width: convolutionWidth,
                        height: convolutionHeight, budget: &trial)
                    loans.append(destination)
                    blurPasses.append(MetalFeatherBlurPass(source: copyTexture, destination: destination,
                        axis: horizontal, horizontal: true,
                        shiftX: blur.reduction == nil ? blur.haloX : 0,
                        shiftY: blur.reduction == nil ? blur.haloY : 0))
                    copyTexture = destination.texture
                }
                if let vertical = blur.vertical {
                    let destination = try resources.groups.acquire(width: convolutionWidth,
                        height: convolutionHeight, budget: &trial)
                    loans.append(destination)
                    blurPasses.append(MetalFeatherBlurPass(source: copyTexture, destination: destination,
                        axis: vertical, horizontal: false,
                        shiftX: blur.reduction == nil && blur.horizontal == nil ? blur.haloX : 0,
                        shiftY: blur.reduction == nil && blur.horizontal == nil ? blur.haloY : 0))
                    copyTexture = destination.texture
                }
                if let reduction = blur.reduction {
                    // 最终clip保持原尺寸；卷积纹理用重算后的真实比例线性回放大。
                    let destination = try resources.groups.acquire(width: blur.width,
                        height: blur.height, budget: &trial)
                    loans.append(destination)
                    upsample = try MetalFeatherResamplePass(source: copyTexture, destination: destination,
                        transform: SIMD4(reduction.scaleX, reduction.scaleY,
                                         Float(-blur.haloX - reduction.sampleLeft) * reduction.scaleX,
                                         Float(-blur.haloY - reduction.sampleTop) * reduction.scaleY))
                    copyTexture = destination.texture
                }
                copyWidth = blur.width
                copyHeight = blur.height
                copyX -= Double(blur.haloX)
                copyY -= Double(blur.haloY)
            }
            let matrix = try SceneAffine.scale(x: Double(copyWidth), y: Double(copyHeight))
                .following(.translation(x: copyX, y: copyY))
            let copy = try MetalFeatherCopy(texture: copyTexture, matrix: matrix,
                targetWidth: effect.overallWidth, targetHeight: effect.overallHeight)
            itemWorks.append(MetalFeatherItemWork(batch: batch, loan: loan,
                                                  downsample: downsample, blurPasses: blurPasses,
                                                  upsample: upsample, copy: copy))
        }
        let overallLoan = try resources.groups.acquire(width: effect.overallWidth,
            height: effect.overallHeight, budget: &trial)
        loans.append(overallLoan)
        let maskLoan = try resources.groups.acquire(width: effect.layout.width,
            height: effect.layout.height, budget: &trial)
        loans.append(maskLoan)
        let overallMatrix = try SceneAffine.scale(x: Double(effect.overallWidth),
            y: Double(effect.overallHeight)).following(effect.overallToLocal)
        let overallCopy = try MetalFeatherCopy(texture: overallLoan.texture, matrix: overallMatrix,
            targetWidth: effect.layout.width, targetHeight: effect.layout.height)
        let work = MetalFeatherWork(content: content, contentLoan: contentLoan, items: itemWorks,
            overallLoan: overallLoan, maskLoan: maskLoan, overallCopy: overallCopy)
        let prepared = MetalFeatherPrepared(work: work, loans: loans,
            contentTexture: contentLoan.texture, maskTexture: maskLoan.texture,
            contentToDisplay: effect.contentToDisplay)
        budget = trial
        committed = true
        return prepared
    }
}
