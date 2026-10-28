import Metal

/// 整层Angle渐变样式的构建步骤，和普通Shape逐图元着色分开。
extension MetalFrameBuilder {
    /// 把Shape原始命令准备为局部源图和样式结果，再按原层顺序绘回显示目标。
    mutating func gradientOverlay(_ overlay: FrameGradientOverlay,
                                  content: ArraySlice<FrameCommand>) throws {
        guard pictureScope == nil, maskScope == nil, parentMaskScope == nil else {
            throw PAGError.unsupportedFeature("gradientOverlayNestedScope")
        }
        var trial = budget
        guard let prepared = try MetalGradientOverlayPreparation.prepare(overlay, commands: content,
            frame: frame, resources: resources, budget: &trial, visible: limit) else {
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
        try replacement.enter(kind: .opacity, clip: nil,
            opacity: overlay.opacity, application: .composite)
        let rectangle = try resources.rectangle(budget: &replacement.budget)
        try replacement.append(mesh: rectangle, texture: prepared.work.result.texture,
            matrix: prepared.toDisplay, color: SIMD4(repeating: 1), clips: replacement.clips)
        try replacement.leave(kind: .opacity)
        replacement.loans += prepared.loans
        replacement.gradientOverlayWorks.append(prepared.work)
        self = replacement
        committed = true
    }
}
