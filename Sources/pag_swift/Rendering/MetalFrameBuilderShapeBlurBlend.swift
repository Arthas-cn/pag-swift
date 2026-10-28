import Metal

/// 把整层Shape滤镜结果以一次HardLight写回当前颜色目标。
extension MetalFrameBuilder {
    /// 准备源坐标模糊并追加最终结果图元；所有借用在失败时归还。
    mutating func shapeBlurBlend(_ effect: FrameShapeBlurBlend,
                                 content: ArraySlice<FrameCommand>) throws {
        guard pictureScope == nil, maskScope == nil, parentMaskScope == nil,
              effect.opacity > 0 else {
            throw PAGError.unsupportedFeature("shapeBlurBlendScope")
        }
        var trial = budget
        guard let prepared = try MetalShapeBlurBlendPreparation.prepare(effect,
            commands: content, frame: frame, resources: resources,
            budget: &trial, visible: limit) else {
            budget = trial
            return
        }
        var committed = false
        defer {
            if !committed {
                prepared.work.releaseTransients()
                for loan in prepared.loans { resources.groups.release(loan) }
            }
        }
        var replacement = self
        replacement.budget = trial
        guard effect.blendMode == .normal || effect.blendMode == .hardLight else {
            throw PAGError.unsupportedFeature("shapeBlurBlendMode")
        }
        let rectangle = try resources.rectangle(budget: &replacement.budget)
        try replacement.append(mesh: rectangle, texture: prepared.work.blur.output,
            matrix: prepared.toDisplay,
            color: SIMD4(repeating: Float(effect.opacity)), clips: replacement.clips,
            hardLightBlend: effect.blendMode == .hardLight)
        replacement.loans += prepared.loans
        replacement.shapeBlurBlendWorks.append(prepared.work)
        self = replacement
        committed = true
    }
}
