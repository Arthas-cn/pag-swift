import Darwin

/// 单项图像相对于总体mask表面的可见窗口，只用于源滤镜样本裁剪。
struct FeatherGaussianClip {
    /// 单项局部图像左边在总体mask表面中的Float坐标。
    let originX: Float
    /// 单项局部图像上边在总体mask表面中的Float坐标。
    let originY: Float
    /// 总体mask表面的正像素宽度。
    let width: Int
    /// 总体mask表面的正像素高度。
    let height: Int
}

/// 一条有界羽化轴的半核；正负偏移共享权重，数组只保存0...radius。
struct FeatherGaussianAxis {
    /// TGFX对Float sigma采用ceil(2×sigma)的半径，最大20。
    let radius: Int
    /// 由Float指数计算并对双侧和归一化的半核权重。
    let weights: [Float]

    /// 零sigma不建立滤镜轴；正sigma按上游半核算式，超过已实现的10像素内部sigma明确失败。
    static func make(_ sigma: Float) throws -> FeatherGaussianAxis? {
        guard sigma.isFinite, sigma >= 0 else { throw PAGError.renderingFailure("featherGaussianSigma") }
        guard sigma > 0 else { return nil }
        guard sigma <= 10 else { throw PAGError.unsupportedFeature("featherMaskBlurScale") }
        let radius = Int((2 * sigma).rounded(.up))
        let denominator = max(2 * sigma * sigma, Float.leastNormalMagnitude)
        var weights: [Float] = []
        weights.reserveCapacity(radius + 1)
        var total: Float = 0
        for index in 0...radius {
            let weight = expf(-Float(index * index) / denominator)
            weights.append(weight)
            total += index == 0 ? weight : 2 * weight
        }
        for index in weights.indices { weights[index] /= total }
        return FeatherGaussianAxis(radius: radius, weights: weights)
    }
}

/// 单项mask模糊的有界输出尺寸及两轴核；源图像外按Decal取零。
struct FeatherGaussianLayout {
    /// 水平方向正sigma时的卷积核；nil只做纵向或不模糊。
    let horizontal: FeatherGaussianAxis?
    /// 垂直方向正sigma时的卷积核。
    let vertical: FeatherGaussianAxis?
    /// Blur滤镜在图像左右所需的整数透明halo。
    let haloX: Int
    /// Blur滤镜在图像上下所需的整数透明halo。
    let haloY: Int
    /// 包含全部halo的输出宽度。
    let width: Int
    /// 包含全部halo的输出高度。
    let height: Int
    /// 原sigma超过10时，先在线性采样的局部纹理降采样，再按实际比例回放大。
    let reduction: FeatherGaussianReduction?

    /// nil feather、负轴或两轴全零直接绘回；可见窗口使大sigma按裁后样本重算缩放。
    static func make(_ feather: ScenePoint?, width: Int, height: Int,
                     clip: FeatherGaussianClip? = nil) throws -> FeatherGaussianLayout? {
        guard let feather else { return nil }
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else {
            throw PAGError.resourceLimitExceeded("featherMaskDimensions")
        }
        let x = Float(feather.x), y = Float(feather.y)
        guard x.isFinite, y.isFinite else { throw PAGError.renderingFailure("featherGaussianSigma") }
        guard x >= 0, y >= 0, x > 0 || y > 0 else { return nil }
        // 输出本身不得超过16384；先限制Float羽化，避免转Int时发生溢出陷阱。
        guard x <= 8_192, y <= 8_192 else { throw PAGError.resourceLimitExceeded("featherMaskDimensions") }
        let sigmaX = x / 2, sigmaY = y / 2
        let horizontal = try FeatherGaussianAxis.make(min(sigmaX, 10))
        let vertical = try FeatherGaussianAxis.make(min(sigmaY, 10))
        // ImageFilter::onFilterBounds各轴外扩2×blurriness，即原feather值。
        let haloX = Int(x.rounded(.up)), haloY = Int(y.rounded(.up))
        let paddedWidth = width.addingReportingOverflow(haloX * 2)
        let paddedHeight = height.addingReportingOverflow(haloY * 2)
        guard !paddedWidth.overflow, !paddedHeight.overflow,
              paddedWidth.partialValue > 0, paddedHeight.partialValue > 0,
              paddedWidth.partialValue <= 16_384, paddedHeight.partialValue <= 16_384,
              UInt128(paddedWidth.partialValue) * UInt128(paddedHeight.partialValue) <= 16_777_216 else {
            throw PAGError.resourceLimitExceeded("featherMaskDimensions")
        }
        let reduction: FeatherGaussianReduction?
        if sigmaX > 10 || sigmaY > 10 {
            let sample = try sampleBounds(width: width, height: height,
                                          featherX: x, featherY: y, clip: clip)
            let factorX = sigmaX > 10 ? 10 / sigmaX : 1
            let factorY = sigmaY > 10 ? 10 / sigmaY : 1
            let reducedWidth = try scaledDimension(left: sample.left, right: sample.right, factor: factorX)
            let reducedHeight = try scaledDimension(left: sample.top, right: sample.bottom, factor: factorY)
            reduction = FeatherGaussianReduction(width: reducedWidth, height: reducedHeight,
                scaleX: Float(reducedWidth) / Float(sample.right - sample.left),
                scaleY: Float(reducedHeight) / Float(sample.bottom - sample.top),
                sampleLeft: sample.left, sampleTop: sample.top)
        } else {
            reduction = nil
        }
        return FeatherGaussianLayout(horizontal: horizontal, vertical: vertical,
            haloX: haloX, haloY: haloY, width: paddedWidth.partialValue,
            height: paddedHeight.partialValue, reduction: reduction)
    }

    /// 滤镜输出先与总体surface可见区域相交并roundOut，再外扩羽化半径取得源样本Rect。
    private static func sampleBounds(width: Int, height: Int, featherX: Float, featherY: Float,
                                     clip: FeatherGaussianClip?) throws
        -> (left: Int, top: Int, right: Int, bottom: Int) {
        let fullLeft = -featherX, fullTop = -featherY
        let fullRight = Float(width) + featherX, fullBottom = Float(height) + featherY
        var clipLeft = fullLeft, clipTop = fullTop
        var clipRight = fullRight, clipBottom = fullBottom
        if let clip {
            guard clip.originX.isFinite, clip.originY.isFinite,
                  clip.width > 0, clip.height > 0 else {
                throw PAGError.renderingFailure("featherGaussianClip")
            }
            clipLeft = max(clipLeft, -clip.originX)
            clipTop = max(clipTop, -clip.originY)
            clipRight = min(clipRight, Float(clip.width) - clip.originX)
            clipBottom = min(clipBottom, Float(clip.height) - clip.originY)
            // 完全落在总体surface外的项不贡献画面，沿用完整样本以免构造零跨度滤镜。
            if clipLeft >= clipRight || clipTop >= clipBottom {
                clipLeft = fullLeft
                clipTop = fullTop
                clipRight = fullRight
                clipBottom = fullBottom
            }
        }
        // ImageFilter::applyCropRect先对输出clip取整；Gaussian再扩样本并与源滤镜边界相交。
        let left = max(fullLeft, clipLeft.rounded(.down) - featherX).rounded(.down)
        let top = max(fullTop, clipTop.rounded(.down) - featherY).rounded(.down)
        let right = min(fullRight, clipRight.rounded(.up) + featherX).rounded(.up)
        let bottom = min(fullBottom, clipBottom.rounded(.up) + featherY).rounded(.up)
        guard let leftValue = Int(exactly: left), let topValue = Int(exactly: top),
              let rightValue = Int(exactly: right), let bottomValue = Int(exactly: bottom),
              leftValue < rightValue, topValue < bottomValue else {
            throw PAGError.resourceLimitExceeded("featherMaskDimensions")
        }
        return (leftValue, topValue, rightValue, bottomValue)
    }

    /// 源样本Rect先按理论sigma比例缩小并逐边roundOut，实际比例随后按整数跨度重算。
    private static func scaledDimension(left: Int, right: Int, factor: Float) throws -> Int {
        let scaledLeft = (Float(left) * factor).rounded(.down)
        let scaledRight = (Float(right) * factor).rounded(.up)
        let span = scaledRight - scaledLeft
        guard span.isFinite, let value = Int(exactly: span), value > 0, value <= 16_384 else {
            throw PAGError.resourceLimitExceeded("featherMaskDimensions")
        }
        return value
    }
}

/// 上游内部sigma钳到10后，用roundOut后的尺寸重算线性降采样倍率。
struct FeatherGaussianReduction {
    /// 降采样和两轴卷积共用的纹理宽度。
    let width: Int
    /// 降采样和两轴卷积共用的纹理高度。
    let height: Int
    /// 源样本扩出范围到降采样纹理的实际水平比例。
    let scaleX: Float
    /// 源样本扩出范围到降采样纹理的实际垂直比例。
    let scaleY: Float
    /// 卷积源样本Rect的局部左边，降采样起点及回放大平移共用。
    let sampleLeft: Int
    /// 卷积源样本Rect的局部上边。
    let sampleTop: Int
}
