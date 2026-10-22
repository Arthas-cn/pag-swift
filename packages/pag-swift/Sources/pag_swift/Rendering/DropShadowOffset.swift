import Darwin

/// 将上游局部角度与距离映到当前drawable像素，不把图层自身缩放重复施于投影。
enum DropShadowOffset {
    /// 源距离非正时返回零；其余先按Float角度算位移，再除本层轴尺度并走最终显示矩阵。
    static func display(style: SourceDropShadow, shadow: FrameDropShadow) throws -> ScenePoint {
        guard style.distance.isFinite, style.angle.isFinite else {
            throw PAGError.renderingFailure("dropShadowOffset")
        }
        guard style.distance > 0 else { return .zero }
        let layer = shadow.layerMatrix
        let xScale = hypot(layer.a, layer.b)
        let yScale = hypot(layer.c, layer.d)
        guard xScale.isFinite, yScale.isFinite, xScale > 0, yScale > 0 else {
            throw PAGError.renderingFailure("dropShadowScale")
        }
        let angle = Float(style.angle) - 180
        let distance = Float(style.distance)
        let radians = angle * (Float.pi / 180)
        let localX = Double(cosf(radians) * distance) / xScale
        let localY = Double(-sinf(radians) * distance) / yScale
        let matrix = shadow.matrix
        let x = matrix.a * localX + matrix.c * localY
        let y = matrix.b * localX + matrix.d * localY
        guard x.isFinite, y.isFinite else { throw PAGError.renderingFailure("dropShadowOffset") }
        return ScenePoint(x: x, y: y)
    }

    /// spread零时把源尺寸变成显示轴的TGFX blurriness；旋转与斜切在局部卷积尚无等价合同。
    static func displayBlurSize(style: SourceDropShadow, shadow: FrameDropShadow) throws -> ScenePoint {
        guard style.spread == 0 else {
            throw PAGError.unsupportedFeature("dropShadowSpread")
        }
        return try displayEffectSize(style: style, shadow: shadow)
    }

    /// spread一时把源扩散半径换算到目标像素；局部形态采样的轴必须与源滤镜轴一致。
    static func displaySpreadSize(style: SourceDropShadow, shadow: FrameDropShadow) throws -> ScenePoint {
        guard style.spread == 1 else { throw PAGError.unsupportedFeature("dropShadowSpread") }
        return try displayEffectSize(style: style, shadow: shadow)
    }

    /// 模糊与扩散共享源层轴尺度抵消；旋转仅在核和显示变换等距时开放。
    static func displayEffectSize(style: SourceDropShadow, shadow: FrameDropShadow) throws -> ScenePoint {
        guard style.size.isFinite, style.size >= 0 else {
            throw PAGError.unsupportedFeature("dropShadowNegativeSize")
        }
        guard style.size > 0 else { return .zero }
        let layer = shadow.layerMatrix
        let matrix = shadow.matrix
        let xScale = hypot(layer.a, layer.b)
        let yScale = hypot(layer.c, layer.d)
        guard xScale.isFinite, yScale.isFinite, xScale > 0, yScale > 0 else {
            throw PAGError.renderingFailure("dropShadowScale")
        }
        let displayX = hypot(matrix.a, matrix.b)
        let displayY = hypot(matrix.c, matrix.d)
        guard displayX.isFinite, displayY.isFinite, displayX > 0, displayY > 0 else {
            throw PAGError.renderingFailure("dropShadowScale")
        }
        let x = displayX * style.size / xScale
        let y = displayY * style.size / yScale
        guard x.isFinite, y.isFinite else { throw PAGError.renderingFailure("dropShadowBlurSize") }
        if matrix.b != 0 || matrix.c != 0 {
            // 圆形核与等距旋转可交换；非正交或两轴实际半径不同必须在源局部滤镜处理。
            let dot = matrix.a * matrix.c + matrix.b * matrix.d
            let scale = max(displayX, displayY)
            let radius = max(x, y)
            guard dot.isFinite, abs(dot) <= scale * scale * 1e-10,
                  abs(displayX - displayY) <= scale * 1e-10,
                  abs(x - y) <= radius * 1e-10 else {
                throw PAGError.unsupportedFeature("dropShadowBlurTransform")
            }
        }
        return ScenePoint(x: x, y: y)
    }
}
