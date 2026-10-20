/// 普通单路径蒙版的不可变采样值；保留有限路径和补集标记，不决定图层可见性或创建GPU资源。
struct SampledMaskPath: Sendable {
    /// 非空TGFX verb语义的源路径；仍可能没有填充面积，不能据此撤销裁剪。
    let path: SourcePath
    /// 已包含首有效Subtract的取反；网格只表示有限路径，显示阶段负责消费补集。
    let isInverted: Bool
}

/// 按源码顺序求值普通蒙版的单路径子范围；多路径布尔、扩张和羽化尚由明确错误守住。
enum MaskPreparation {
    /// 按调用方已选好的父合成帧采样；nil表示无裁剪，预算、取消或未实现语义不返回部分结果。
    static func singlePath(_ masks: [SourceMask], at frame: Int64,
                           budget: inout FramePlanBudget) throws -> SampledMaskPath? {
        try Task.checkCancellation()
        for mask in masks {
            try Task.checkCancellation()
            try budget.reserve(stride: 32)
            // LayerCache先对整层选择分支，None或开放路径也不能隐藏羽化/opacity轨道。
            guard mask.feather == nil, !mask.opacity.isAnimated, mask.opacity.initialValue == 255 else {
                throw PAGError.unsupportedFeature("featherMask")
            }
        }
        var result: SampledMaskPath?
        var hasEffectivePath = false
        for mask in masks {
            try Task.checkCancellation()
            try budget.reserve(stride: 32)
            let path = try PropertyEvaluation.path(mask.path, at: frame, budget: &budget)
            guard path.verbs.last == .close, mask.mode != .none else { continue }
            // 仅Close最终可转为无clip，但仍消耗首项；不能先丢弃它再将后项当首Subtract。
            guard !hasEffectivePath else { throw PAGError.unsupportedFeature("multipleMaskPaths") }
            hasEffectivePath = true
            guard !mask.expansion.isAnimated, mask.expansion.initialValue == 0 else {
                throw PAGError.unsupportedFeature("maskExpansion")
            }
            guard try hasNormalizedVerbs(path, budget: &budget) else { continue }
            try budget.reserve(stride: 128)
            try budget.reserve(stride: path.estimatedBytes)
            result = SampledMaskPath(path: path, isInverted: mask.isInverted != (mask.mode == .subtract))
        }
        try Task.checkCancellation()
        return result
    }

    /// ToPath的Close在空路径上不写verb，Move/Line/Cubic则一定生成verb；面积不参与这个判断。
    private static func hasNormalizedVerbs(_ path: SourcePath, budget: inout FramePlanBudget) throws -> Bool {
        for verb in path.verbs {
            try Task.checkCancellation()
            try budget.reserve(stride: 8)
            if verb != .close { return true }
        }
        return false
    }
}
