import Metal

/// 只负责Glow后Gaussian局部附件接线；组生命周期和根drawable由主构建器管理。
extension MetalFrameBuilder {
    /// 借齐Merge、缩采、有效轴和输出附件，失败时统一由帧准备的defer归还。
    mutating func attachFastBlur(_ value: SampledFastBlur, clip: FrameClip?,
                                 original: MetalGroupAttachment, glow: MetalGlowInput,
                                 rect: RenderPixelRect, contentPassIndex: Int)
        throws -> (texture: any MTLTexture, rect: RenderPixelRect) {
        guard let clip else { throw PAGError.renderingFailure("fastBlurCompositionClip") }
        let scale = try FastBlurSampling.displayScale(of: clip.matrix)
        let sampled = try FastBlurSampling(value, effectScaleX: 1, effectScaleY: 1,
                                            sourceScale: scale)
        let layout = try FastBlurTextureLayout(sampled, width: rect.width, height: rect.height)
        let merged = try borrowFastBlur(width: rect.width, height: rect.height)
        let reduced = try borrowFastBlur(width: layout.x.reducedLength,
                                         height: layout.y.reducedLength)
        var horizontal: MetalGroupAttachment?
        if layout.x.kernel != nil {
            horizontal = try borrowFastBlur(width: layout.x.reducedLength,
                                             height: layout.y.reducedLength)
        }
        var vertical: MetalGroupAttachment?
        if layout.y.kernel != nil {
            vertical = try borrowFastBlur(width: layout.x.reducedLength,
                                           height: layout.y.reducedLength)
        }
        let output = try borrowFastBlur(width: layout.x.outputLength,
                                        height: layout.y.outputLength)
        let x = rect.x.addingReportingOverflow(layout.x.outputLeft)
        let y = rect.y.addingReportingOverflow(layout.y.outputLeft)
        guard !x.overflow, !y.overflow else {
            throw PAGError.resourceLimitExceeded("fastBlurDimensions")
        }
        let merge = MetalGlowMergePass(source: original.texture, blurred: glow.texture,
                                       destination: merged.texture, threshold: glow.threshold)
        let work = MetalFastBlurWork(source: merged.texture, reduced: reduced.texture,
            horizontal: horizontal?.texture, vertical: vertical?.texture, output: output.texture,
            layout: layout, repeatEdgePixels: value.repeatEdgePixels)
        fastBlurWorks[contentPassIndex] = MetalGlowFastBlurWork(merge: merge, blur: work)
        return (output.texture, RenderPixelRect(x: x.partialValue, y: y.partialValue,
                                                width: layout.x.outputLength,
                                                height: layout.y.outputLength))
    }

    /// 单张附件在同一帧预算内借用，立即登记供任意后续失败回收。
    private mutating func borrowFastBlur(width: Int, height: Int) throws -> MetalGroupAttachment {
        let loan = try resources.groups.acquire(width: width, height: height, budget: &budget)
        loans.append(loan)
        return loan
    }
}
