/// 普通单路径蒙版的不可变采样值；保留有限路径和补集标记，不决定图层可见性或创建GPU资源。
struct SampledMaskPath: Sendable {
    /// 非空TGFX verb语义的源路径；仍可能没有填充面积，不能据此撤销裁剪。
    let path: SourcePath
    /// 已包含首有效Subtract的取反；网格只表示有限路径，显示阶段负责消费补集。
    let isInverted: Bool
}

/// 一条有序Boolean源项；保留路径对象身份、模式和本项反向语义供后续网格缓存使用。
struct SampledMaskTerm: Sendable {
    /// 在所属合成帧采样的原始路径，可能只有Close而被TGFX归一化为空verb。
    let path: SourcePath
    /// 首项直接设为基底，后续项按上游映射到几何Boolean。
    let mode: SourceMaskMode
    /// 只属于本源项的inverse位；首Subtract的翻转在最终远场计算时处理。
    let isInverted: Bool
    /// 该父合成帧的Float扩张值；零值不进入描边，正负值在本项内部先做并/差。
    let expansion: Float

    /// 固定源身份、顺序和该帧扩张，失败由表达式构造器统一检查。
    init(path: SourcePath, mode: SourceMaskMode, isInverted: Bool, expansion: Float = 0) {
        self.path = path
        self.mode = mode
        self.isInverted = isInverted
        self.expansion = expansion
    }
}

/// 同一图层的扩张路径或多路径Boolean，源顺序和值共同决定网格缓存身份。
struct SampledMaskExpression: Sendable {
    /// 一条非零扩张路径，或至少两条普通路径；均已通过闭合与None过滤。
    let terms: [SampledMaskTerm]
    /// 全部有限轮廓外的布尔真值；GPU对最终有限网格应用此补集位。
    let isInverted: Bool
    /// 保活全部路径与模式的保守成本，不含曲线细分和GPU上传网格。
    let estimatedBytes: Int

    /// 保存不可变源列表，并按源码顺序求远场；成本溢出明确失败。
    init(terms: [SampledMaskTerm]) throws {
        guard !terms.isEmpty, terms.count > 1 || terms[0].expansion != 0 else {
            throw PAGError.invalidArgument("maskBooleanOperands")
        }
        var bytes = 128
        var outside = terms[0].isInverted != (terms[0].mode == .subtract)
        for (index, term) in terms.enumerated() {
            try Task.checkCancellation()
            guard term.mode != .none else { throw PAGError.invalidArgument("maskBooleanMode") }
            guard term.expansion.isFinite else { throw PAGError.invalidArgument("maskExpansion") }
            let item = term.path.estimatedBytes.addingReportingOverflow(48)
            let total = bytes.addingReportingOverflow(item.partialValue)
            guard !item.overflow, !total.overflow else {
                throw PAGError.resourceLimitExceeded("maximumFramePlanBytes")
            }
            bytes = total.partialValue
            guard index > 0 else { continue }
            switch term.mode {
            case .subtract: outside = outside && !term.isInverted
            case .intersect, .darken: outside = outside && term.isInverted
            case .difference: outside = outside != term.isInverted
            case .add, .lighten, .accumulate: outside = outside || term.isInverted
            case .none: throw PAGError.invalidArgument("maskBooleanMode")
            }
        }
        self.terms = terms
        isInverted = outside
        estimatedBytes = bytes
    }
}

/// 零扩张单路径沿原缓存身份处理，其余保留完整有序表达式；nil只表示无裁剪。
enum SampledMaskValue: Sendable {
    /// 一条有verb路径及其首项反向规则。
    case path(SampledMaskPath)
    /// 一条扩张路径或至少两条有效路径，不以原单路径键错误复用。
    case expression(SampledMaskExpression)
}

/// 按源码顺序求值普通蒙版；非零扩张保留本帧值，羽化仍明确拒绝。
enum MaskPreparation {
    /// 按源顺序采样普通路径；多项保留空verb首项以供后续PathKit空结果门禁判定。
    static func orderedPaths(_ masks: [SourceMask], at frame: Int64,
                             budget: inout FramePlanBudget) throws -> SampledMaskValue? {
        try Task.checkCancellation()
        for mask in masks {
            try Task.checkCancellation()
            try budget.reserve(stride: 32)
            // LayerCache的羽化分流针对完整列表，不能先按None或开放路径过滤。
            guard mask.feather == nil, !mask.opacity.isAnimated, mask.opacity.initialValue == 255 else {
                throw PAGError.unsupportedFeature("featherMask")
            }
        }
        var terms: [SampledMaskTerm] = []
        for mask in masks {
            try Task.checkCancellation()
            try budget.reserve(stride: 32)
            let path = try PropertyEvaluation.path(mask.path, at: frame, budget: &budget)
            guard path.verbs.last == .close, mask.mode != .none else { continue }
            let expansion = Float(try PropertyEvaluation.scalar(mask.expansion, at: frame))
            guard expansion.isFinite else { throw SceneValidator.invalid("unrepresentablePropertyValue") }
            // Float乘二可能溢出；上游PathKit在非有限描边结果上会重置路径，不能猜测画面。
            guard (abs(expansion) * 2).isFinite else {
                throw PAGError.resourceLimitExceeded("maximumStrokeMagnitude")
            }
            try budget.reserve(stride: 48)
            try budget.reserve(stride: path.estimatedBytes)
            terms.append(SampledMaskTerm(path: path, mode: mask.mode, isInverted: mask.isInverted,
                                         expansion: expansion == 0 ? 0 : expansion))
        }
        try Task.checkCancellation()
        guard let first = terms.first else { return nil }
        if terms.count == 1 {
            guard try hasNormalizedVerbs(first.path, budget: &budget) else { return nil }
            // 细到TGFX hairline阈值的负扩张仍与自身作Difference，PathKit给出零verb；
            // LayerCache将它当无裁剪，不能让空网格进入普通隐藏分支。
            if first.expansion < 0, abs(first.expansion) * 2 <= 1.0 / 4096 { return nil }
            if first.expansion == 0 {
                try budget.reserve(stride: 128)
                return .path(SampledMaskPath(path: first.path,
                                             isInverted: first.isInverted != (first.mode == .subtract)))
            }
        }
        // PathKit把负hairline差集归一化为零verb；后续只有交集或差集时仍为零verb，
        // LayerCache对此撤销裁剪，不能发布空网格使Metal误判为整层隐藏。
        if try hasKnownZeroVerbResult(terms, budget: &budget) { return nil }
        try budget.reserve(stride: 128)
        return .expression(try SampledMaskExpression(terms: terms))
    }

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

    /// 只识别上游空路径Boolean规则可严格证明的链；其他空面积仍交给正式几何门禁。
    private static func hasKnownZeroVerbResult(_ terms: [SampledMaskTerm],
                                               budget: inout FramePlanBudget) throws -> Bool {
        guard terms.count > 1, let first = terms.first,
              first.expansion < 0, abs(first.expansion) * 2 <= 1.0 / 4096,
              !first.isInverted, first.mode != .subtract else { return false }
        for term in terms.dropFirst() {
            try Task.checkCancellation()
            try budget.reserve(stride: 8)
            guard term.mode == .intersect || term.mode == .darken || term.mode == .subtract else {
                return false
            }
        }
        return true
    }
}
