import Darwin

/// FastBlur的原始方向、上游缩放和边界求值；局部附件尺寸另按roundOut确定。
struct FastBlurSampling: Sendable {
    /// 真正送入TGFX Gaussian的水平像素sigma，可大于内部10像素上限。
    let sigmaX: Float
    /// 真正送入TGFX Gaussian的垂直像素sigma。
    let sigmaY: Float
    /// `transformBounds`在图层坐标的水平单侧外扩，Clamp时为零。
    let outsetX: Float
    /// `transformBounds`在图层坐标的垂直单侧外扩，Clamp时为零。
    let outsetY: Float
    /// true要求源外重复边缘，false要求透明Decal。
    let repeatEdgePixels: Bool

    /// 直接显示像素域只接受等距变换；非等距须先建立独立源图域后才能保证两轴sigma。
    static func displayScale(of matrix: SceneAffine) throws -> Float {
        let a = Float(matrix.a), b = Float(matrix.b), c = Float(matrix.c), d = Float(matrix.d)
        let xSquared = a * a + b * b
        let ySquared = c * c + d * d
        let dot = a * c + b * d
        guard xSquared.isFinite, ySquared.isFinite, dot.isFinite,
              xSquared > 0, ySquared > 0 else {
            throw PAGError.unsupportedFeature("fastBlurDisplayScale")
        }
        let tolerance = max(xSquared, ySquared) * 0.0001
        guard abs(xSquared - ySquared) <= tolerance, abs(dot) <= tolerance else {
            throw PAGError.unsupportedFeature("fastBlurNonUniformTransform")
        }
        let scale = sqrt(max(xSquared, ySquared))
        guard scale.isFinite, scale > 0 else {
            throw PAGError.unsupportedFeature("fastBlurDisplayScale")
        }
        return scale
    }

    /// 按上游两条不同尺度路径求值，拒绝负值或不可表示的像素sigma。
    init(_ value: SampledFastBlur, effectScaleX: Float, effectScaleY: Float,
         sourceScale: Float) throws {
        let blur = Float(value.blurriness)
        guard blur.isFinite, blur >= 0, effectScaleX.isFinite, effectScaleY.isFinite,
              sourceScale.isFinite, effectScaleX > 0, effectScaleY > 0, sourceScale > 0,
              value.direction <= 2 else {
            throw PAGError.unsupportedFeature("fastBlurScale")
        }
        let horizontal = value.direction != 2
        let vertical = value.direction != 1
        let x = horizontal ? blur * effectScaleX * sourceScale / 2 : 0
        let y = vertical ? blur * effectScaleY * sourceScale / 2 : 0
        // 上游All方向的范围计算故意不乘effectScale；仅单轴方向乘活动轴尺度。
        let boundX = value.direction == 0 ? blur : (horizontal ? blur * effectScaleX : 0)
        let boundY = value.direction == 0 ? blur : (vertical ? blur * effectScaleY : 0)
        guard x.isFinite, y.isFinite, boundX.isFinite, boundY.isFinite else {
            throw PAGError.unsupportedFeature("fastBlurScale")
        }
        sigmaX = x
        sigmaY = y
        outsetX = value.repeatEdgePixels ? 0 : boundX
        outsetY = value.repeatEdgePixels ? 0 : boundY
        repeatEdgePixels = value.repeatEdgePixels
    }
}
