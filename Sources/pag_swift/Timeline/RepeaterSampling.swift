import Foundation

/// 一份已求值的重复组变换；原组alpha在克隆节点后再乘此系数。
struct RepeaterCopy: Sendable {
    /// 对应上游从零递增的复制序号，Above只改变输出顺序。
    let sourceIndex: Int
    /// 原组局部坐标到重复后组坐标的变换。
    let matrix: SceneAffine
    /// 末份小数系数与起止透明度插值的积，范围0...1。
    let opacity: Double
}

/// copies的三种组行为；负值不修改原组，零值移除此前内容。
enum RepeaterSelection: Sendable {
    /// 负份数沿用此前已求值的全部组元素。
    case unchanged
    /// 零份数清空此前已求值的全部组元素。
    case cleared
    /// 正份数按Above/Below最终覆盖顺序保存每份变换。
    case copies([RepeaterCopy])
}

/// 按ShapeRenderer::ApplyRepeater求每份矩阵和alpha；不展开节点或触及Metal。
enum RepeaterSampling {
    /// 先完整预留复制描述符预算，再以所属合成帧采样；不可表示的Float运算明确失败。
    static func select(_ source: SourceRepeater, at frame: Int64,
                       budget: inout FramePlanBudget) throws -> RepeaterSelection {
        try Task.checkCancellation()
        let copies = Float(try PropertyEvaluation.scalar(source.copies, at: frame))
        guard copies.isFinite else { throw SceneValidator.invalid("unrepresentableRepeater") }
        if copies < 0 { return .unchanged }
        if copies == 0 { return .cleared }
        let rounded = ceilf(copies)
        let stride = MemoryLayout<RepeaterCopy>.stride + 64
        // 源可能给出巨大Float份数；在转Int或分配数组前按剩余额度拒绝。
        guard rounded.isFinite, Double(rounded) <= Double((budget.limit - budget.used) / stride) else {
            throw PAGError.resourceLimitExceeded("maximumFramePlanBytes")
        }
        let count = Int(rounded)
        try budget.reserve(count: count, stride: stride)
        let offset = Float(try PropertyEvaluation.scalar(source.offset, at: frame))
        let anchor = try PropertyEvaluation.point(source.anchor, at: frame)
        let position = try PropertyEvaluation.point(source.position, at: frame)
        let scale = try PropertyEvaluation.point(source.scale, at: frame)
        let rotation = Float(try PropertyEvaluation.scalar(source.rotation, at: frame))
        let start = try PropertyEvaluation.opacity(source.startOpacity, at: frame)
        let end = try PropertyEvaluation.opacity(source.endOpacity, at: frame)
        guard offset.isFinite, rotation.isFinite else { throw SceneValidator.invalid("unrepresentableRepeater") }
        var result: [RepeaterCopy] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            try Task.checkCancellation()
            let progress = Float(index) + offset
            let scaleX = powf(Float(scale.x), progress)
            let scaleY = powf(Float(scale.y), progress)
            let angle = rotation * progress
            let positionX = Float(position.x) * progress
            let positionY = Float(position.y) * progress
            guard progress.isFinite, scaleX.isFinite, scaleY.isFinite, angle.isFinite,
                  positionX.isFinite, positionY.isFinite else {
                throw SceneValidator.invalid("unrepresentableRepeater")
            }
            // TGFX的post操作按后续左乘排列；锚点须在缩放之前减、位移之后加。
            let matrix = try SceneAffine.translation(x: -anchor.x, y: -anchor.y)
                .following(.scale(x: Double(scaleX), y: Double(scaleY)))
                .following(.rotation(degrees: Double(angle)))
                .following(.translation(x: Double(positionX), y: Double(positionY)))
                .following(.translation(x: anchor.x, y: anchor.y))
            let fraction = index == count - 1 && progress != copies + offset ? copies - Float(index) : 1
            let amount = Float(start) + (Float(end) - Float(start)) * (progress / rounded)
            guard amount.isFinite else { throw SceneValidator.invalid("unrepresentableRepeater") }
            // 上游UInt8 Interpolate先截断到字节，再由ToAlpha映到0...1。
            let opacity = UInt8(min(255, max(0, amount)))
            result.append(RepeaterCopy(sourceIndex: index, matrix: matrix,
                                       opacity: Double(fraction * (Float(opacity) / 255))))
        }
        if source.order == .above { result.reverse() }
        return .copies(result)
    }
}
