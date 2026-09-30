/// 最终显示目标中的像素裁剪矩形；纯值表示，不持有平台绘制对象。
struct DisplayRect: Sendable, Equatable {
    /// 左边界的像素坐标。
    let x: Double
    /// 上边界的像素坐标。
    let y: Double
    /// 正像素宽度；实际设备整数分配在显示阶段校验。
    let width: Double
    /// 正像素高度；实际设备整数分配在显示阶段校验。
    let height: Double

    /// 保存已经过显示变换校验的目标边界，不自行申请像素资源。
    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// 将合成坐标居中映射为显示像素的仿射系数，供所有平台宿主共同使用。
struct DisplayTransform: Sendable, Equatable {
    /// x 对 x 的缩放系数，已包含显示像素倍率。
    let a: Double
    /// x 对 y 的剪切系数；四种公开缩放策略均为零。
    let b: Double
    /// y 对 x 的剪切系数；四种公开缩放策略均为零。
    let c: Double
    /// y 对 y 的缩放系数，已包含显示像素倍率。
    let d: Double
    /// 居中后的水平像素偏移，裁切模式下可以为负。
    let tx: Double
    /// 居中后的垂直像素偏移，裁切模式下可以为负。
    let ty: Double
    /// 所有模式共同使用的最终显示边界。
    let clipRect: DisplayRect

    /// 建立最终显示变换；倍率无效或浮点运算溢出/下溢至零时抛 invalidArgument。
    init(contentSize: PAGSize, targetSize: PAGSize, scale: Double, mode: PAGScaleMode) throws {
        guard scale.isFinite, scale > 0 else { throw PAGError.invalidArgument("scale") }
        let horizontal = targetSize.width / contentSize.width
        let vertical = targetSize.height / contentSize.height
        let sx: Double
        let sy: Double
        switch mode {
        case .none:
            // 不缩放表示逻辑点一比一；高倍率显示仍需统一换算成实际像素。
            sx = 1
            sy = 1
        case .stretch:
            sx = horizontal
            sy = vertical
        case .aspectFit:
            sx = min(horizontal, vertical)
            sy = sx
        case .aspectFill:
            sx = max(horizontal, vertical)
            sy = sx
        }
        let a = sx * scale
        let d = sy * scale
        let tx = (targetSize.width - contentSize.width * sx) / 2 * scale
        let ty = (targetSize.height - contentSize.height * sy) / 2 * scale
        let width = targetSize.width * scale
        let height = targetSize.height * scale
        guard [a, d, tx, ty, width, height].allSatisfy(\.isFinite),
              a > 0, d > 0, width > 0, height > 0 else {
            throw PAGError.invalidArgument("displayTransform")
        }
        self.a = a
        b = 0
        c = 0
        self.d = d
        self.tx = tx
        self.ty = ty
        clipRect = DisplayRect(x: 0, y: 0, width: width, height: height)
    }
}
