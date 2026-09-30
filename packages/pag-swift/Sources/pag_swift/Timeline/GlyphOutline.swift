import CoreGraphics

/// 不可变字形矢量路径，所有坐标已转换为 PAG 向下的 y 轴；不携带 CGPath。
final class GlyphOutline: Sendable {
    /// 顺序路径元素；空数组表示没有覆盖像素的空格、控制 glyph 或缺字。
    let elements: [GlyphPathElement]

    /// 接收经过数值与预算验证的元素，之后仅共享不修改。
    init(elements: [GlyphPathElement]) { self.elements = elements }

    /// 在后台系统路径作用域内复制纯值元素；回调中的失败在枚举结束后统一抛出。
    static func copy(_ path: CGPath?, budget: inout FramePlanBudget) throws -> GlyphOutline {
        try Task.checkCancellation()
        try budget.reserve(stride: 128)
        guard let path else { return GlyphOutline(elements: []) }
        var builder = GlyphPathBuilder(budget: budget)
        path.applyWithBlock { element in
            // CGPath 枚举回调不能抛出或提前取消；第一次失败之后不再分配，结束后丢弃部分路径。
            guard builder.failure == nil else { return }
            do { try builder.append(element.pointee) }
            catch { builder.failure = error }
        }
        budget = builder.budget
        if let failure = builder.failure { throw failure }
        try Task.checkCancellation()
        return GlyphOutline(elements: builder.elements)
    }
}

/// 字体轮廓的原始曲线元素；没有在准备阶段按屏幕精度细分或栅格化。
enum GlyphPathElement: Sendable, Equatable {
    /// 开始一个新轮廓，关联值是该轮廓起点。
    case move(ScenePoint)
    /// 从当前位置连直线到关联终点。
    case line(ScenePoint)
    /// 二次曲线，依次给出控制点和终点。
    case quadratic(control: ScenePoint, end: ScenePoint)
    /// 三次曲线，依次给出两个控制点和终点。
    case cubic(first: ScenePoint, second: ScenePoint, end: ScenePoint)
    /// 闭合当前轮廓，保留字体原本的绕序和孔洞。
    case close
}

/// 一次 CGPath 枚举的局部累积，不跨暂停点、不在任务间共享。
private struct GlyphPathBuilder {
    /// 该路径开始时的共享准备计费，回调每增长一个元素先预留。
    var budget: FramePlanBudget
    /// 已复制的纯值元素；发生错误时整体丢弃。
    var elements: [GlyphPathElement] = []
    /// 回调遇到的第一个错误；nil 表示仍可继续累积。
    var failure: (any Error)?

    /// 将 CoreGraphics 元素转换为有限 Float 精度的 PAG 坐标；未知元素明确失败。
    mutating func append(_ element: CGPathElement) throws {
        try Task.checkCancellation()
        try budget.reserve(stride: 128)
        switch element.type {
        case .moveToPoint: elements.append(.move(try point(element.points[0])))
        case .addLineToPoint: elements.append(.line(try point(element.points[0])))
        case .addQuadCurveToPoint:
            elements.append(.quadratic(control: try point(element.points[0]), end: try point(element.points[1])))
        case .addCurveToPoint:
            elements.append(.cubic(first: try point(element.points[0]), second: try point(element.points[1]), end: try point(element.points[2])))
        case .closeSubpath: elements.append(.close)
        @unknown default: throw PAGError.unsupportedFeature("textPathElement")
        }
    }

    /// 上游路径接收 Float 并翻转 y；非有限转换不得进入 Sendable 资源。
    private func point(_ point: CGPoint) throws -> ScenePoint {
        let x = try TextLayoutSettings.finite(Float(point.x))
        let y = try TextLayoutSettings.finite(-Float(point.y))
        return ScenePoint(x: Double(x), y: Double(y))
    }
}
