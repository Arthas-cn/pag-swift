import Foundation

/// 羽化内容/蒙版共用的局部表面布局；只有效果范围，不代表公共整帧中转。
struct FeatherMaskSurfaceLayout: Sendable {
    /// 先与FeatherMask总体范围相交、必要时向外取整的源坐标范围。
    let bounds: RenderBounds
    /// SurfaceUtil按1/20向上量化后的父canvas最大轴倍率。
    let scale: Float
    /// 局部内容与蒙版附件共用的正像素宽度。
    let width: Int
    /// 局部内容与蒙版附件共用的正像素高度。
    let height: Int
    /// 将源坐标映射到局部附件像素，平移按Float矩阵运算保存。
    let contentMatrix: SceneAffine
}

/// 复现MaskModifier与SurfaceUtil的裁交、条件roundOut和1/20缩放量化。
enum FeatherMaskSurfacePreparation {
    /// 内容和蒙版无正面积交集时返回nil；异常尺寸、矩阵或预算失败不分配GPU附件。
    static func layout(content: RenderBounds, mask: RenderBounds, parentMatrix: SceneAffine,
                       budget: inout MetalFrameBudget) throws -> FeatherMaskSurfaceLayout? {
        try Task.checkCancellation()
        try budget.reserve(128)
        let original = try floatBounds(content)
        let measured = try floatBounds(mask)
        let left = max(original.left, measured.left)
        let top = max(original.top, measured.top)
        let right = min(original.right, measured.right)
        let bottom = min(original.bottom, measured.bottom)
        // MaskModifier只在非反向分支相交；FeatherMaskCache固定以inverted=false建立它。
        guard left < right, top < bottom else { return nil }
        let cropped = left != original.left || top != original.top
            || right != original.right || bottom != original.bottom
        let x = cropped ? left.rounded(.down) : left
        let y = cropped ? top.rounded(.down) : top
        let r = cropped ? right.rounded(.up) : right
        let b = cropped ? bottom.rounded(.up) : bottom
        let values = [parentMatrix.a, parentMatrix.b, parentMatrix.c, parentMatrix.d].map(Float.init)
        guard values.allSatisfy(\.isFinite) else { throw SceneValidator.invalid("unrepresentableTransform") }
        // TGFX取矩阵两列长度的较大者，不使用可选Picture的最大奇异值。
        let axisX = Float(sqrt(Double(values[0]) * Double(values[0])
                             + Double(values[1]) * Double(values[1])))
        let axisY = Float(sqrt(Double(values[2]) * Double(values[2])
                             + Double(values[3]) * Double(values[3])))
        let parentScale = max(axisX, axisY)
        guard parentScale.isFinite, parentScale > 0 else {
            throw PAGError.resourceLimitExceeded("featherMaskScale")
        }
        // SurfaceUtil本调用scale=1、limit=FLT_MAX，先Float乘20、ceil再Float除20。
        let scaled = parentScale * 20
        let scale = scaled.rounded(.up) / 20
        guard scale.isFinite, scale > 0 else { throw PAGError.resourceLimitExceeded("featherMaskScale") }
        let pixelWidth = ((r - x) * scale).rounded(.up)
        let pixelHeight = ((b - y) * scale).rounded(.up)
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              let width = Int(exactly: pixelWidth), let height = Int(exactly: pixelHeight),
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              UInt128(width) * UInt128(height) <= 16_777_216 else {
            throw PAGError.resourceLimitExceeded("metalGroupDimensions")
        }
        let bounds = try RenderBounds(left: Double(x), top: Double(y), right: Double(r), bottom: Double(b))
        // Matrix::preTranslate在当前scale之后执行，平移分量须先按Float求值。
        let matrix = try SceneAffine(a: Double(scale), b: 0, c: 0, d: Double(scale),
                                     tx: Double(-x * scale), ty: Double(-y * scale))
        try Task.checkCancellation()
        return FeatherMaskSurfaceLayout(bounds: bounds, scale: scale, width: width, height: height,
                                        contentMatrix: matrix)
    }

    /// 源TGFX Rect四边均为Float；源范围不能用超出Float的Double悄然进入局部尺寸。
    private static func floatBounds(_ value: RenderBounds) throws -> (left: Float, top: Float, right: Float, bottom: Float) {
        let left = Float(value.left), top = Float(value.top)
        let right = Float(value.right), bottom = Float(value.bottom)
        guard [left, top, right, bottom].allSatisfy(\.isFinite) else {
            throw PAGError.resourceLimitExceeded("featherMaskBounds")
        }
        return (left, top, right, bottom)
    }
}
