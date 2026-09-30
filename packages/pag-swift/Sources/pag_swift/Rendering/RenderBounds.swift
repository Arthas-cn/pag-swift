import Foundation

/// 渲染准备层的有限轴对齐范围，只用于保守分配/剔除，不替代真实裁剪。
struct RenderBounds: Sendable, Equatable {
    /// 包围范围左边界；允许负坐标与零宽度。
    let left: Double
    /// 包围范围上边界；PAG坐标向下为正。
    let top: Double
    /// 不小于left的右边界。
    let right: Double
    /// 不小于top的下边界。
    let bottom: Double

    /// 拒绝非有限或倒置范围，退化范围用于逐点累计。
    init(left: Double, top: Double, right: Double, bottom: Double) throws {
        guard [left, top, right, bottom].allSatisfy(\.isFinite), left <= right, top <= bottom else {
            throw PAGError.renderingFailure("metalBounds")
        }
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    /// 合并有限范围；两个来源的并集仍然有界。
    func union(_ other: RenderBounds) -> RenderBounds {
        // 两端都来自已验证范围，min/max不会引入无穷或倒置。
        try! RenderBounds(left: min(left, other.left), top: min(top, other.top),
                          right: max(right, other.right), bottom: max(bottom, other.bottom))
    }

    /// 正面积交集；相离或仅边界接触返回nil。
    func intersection(_ other: RenderBounds) -> RenderBounds? {
        let l = max(left, other.left), t = max(top, other.top)
        let r = min(right, other.right), b = min(bottom, other.bottom)
        guard l < r, t < b else { return nil }
        return try? RenderBounds(left: l, top: t, right: r, bottom: b)
    }

    /// 补回网格原点后变换四角，所得范围包含全部仿射变换后的三角形。
    func transformed(by matrix: SceneAffine, origin: ScenePoint = .zero) throws -> RenderBounds {
        let points = try [ScenePoint(x: left, y: top), ScenePoint(x: right, y: top),
                          ScenePoint(x: left, y: bottom), ScenePoint(x: right, y: bottom)].map {
            try matrix.applying(to: ScenePoint(x: $0.x + origin.x, y: $0.y + origin.y))
        }
        return try RenderBounds(left: points.map(\.x).min()!, top: points.map(\.y).min()!,
                                right: points.map(\.x).max()!, bottom: points.map(\.y).max()!)
    }

    /// 给边缘覆盖预留一个像素，再裁到已有显示/祖先范围并向外取整；空交集不分配。
    func pixelRect(clippedTo limit: RenderBounds) throws -> RenderPixelRect? {
        let expanded = try RenderBounds(left: left - 1, top: top - 1, right: right + 1, bottom: bottom + 1)
        guard let value = expanded.intersection(limit) else { return nil }
        guard let x = Int(exactly: floor(value.left)), let y = Int(exactly: floor(value.top)),
              let r = Int(exactly: ceil(value.right)), let b = Int(exactly: ceil(value.bottom)),
              r > x, b > y else {
            throw PAGError.resourceLimitExceeded("metalGroupDimensions")
        }
        let width = r.subtractingReportingOverflow(x), height = b.subtractingReportingOverflow(y)
        guard !width.overflow, !height.overflow, width.partialValue <= 16_384, height.partialValue <= 16_384 else {
            throw PAGError.resourceLimitExceeded("metalGroupDimensions")
        }
        return RenderPixelRect(x: x, y: y, width: width.partialValue, height: height.partialValue)
    }
}

/// 已裁到显示范围的整数像素附件区域，不表示公共离屏画布。
struct RenderPixelRect: Sendable, Equatable {
    /// 附件左上角在最终显示中的像素x。
    let x: Int
    /// 附件左上角在最终显示中的像素y。
    let y: Int
    /// 正像素宽度，由准备入口验证。
    let width: Int
    /// 正像素高度，由准备入口验证。
    let height: Int
    /// 用于Double NDC原点补偿的显示坐标。
    var origin: ScenePoint { ScenePoint(x: Double(x), y: Double(y)) }
    /// 对应的连续像素边界；调用者只构造经过预算验证的正区域。
    var bounds: RenderBounds {
        try! RenderBounds(left: Double(x), top: Double(y), right: Double(x) + Double(width), bottom: Double(y) + Double(height))
    }
}
