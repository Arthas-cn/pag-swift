/// FastBlur一个像素轴的原图、源采样、缩采和最终输出关系，均在局部滤镜坐标系。
struct FastBlurTextureAxis: Sendable {
    /// 原输入图像的整数像素跨度。
    let sourceLength: Int
    /// 滤镜输出图像的整数像素跨度，Clamp保持原值。
    let outputLength: Int
    /// 输出图像相对输入原点的有符号像素起点。
    let outputLeft: Int
    /// 内部源样本相对输入原点的有符号起点。
    let sampleLeft: Int
    /// 内部源样本经roundOut后的原始跨度。
    let sampleLength: Int
    /// 上游按理论倍率缩采并roundOut后的附件跨度。
    let reducedLength: Int
    /// 从取整后跨度重算的实际缩采倍率。
    let actualScale: Float
    /// TGFX限制到10像素后的半核；零轴不建立卷积。
    let kernel: FeatherGaussianAxis?

    /// 从源像素sigma构造对称halo和内部缩采；所有范围在转Int前有界检查。
    init(sourceLength: Int, sigma: Float, repeatEdgePixels: Bool) throws {
        guard sourceLength > 0, sourceLength <= 16_384, sigma.isFinite, sigma >= 0,
              sigma <= 4_096 else {
            throw PAGError.resourceLimitExceeded("fastBlurDimensions")
        }
        let halo = Int((2 * sigma).rounded(.up))
        let sample = sourceLength.addingReportingOverflow(2 * halo)
        guard !sample.overflow, sample.partialValue > 0, sample.partialValue <= 16_384 else {
            throw PAGError.resourceLimitExceeded("fastBlurDimensions")
        }
        let factor = sigma > 10 ? 10 / sigma : 1
        let scaledLeft = (Float(-halo) * factor).rounded(.down)
        let scaledRight = (Float(sourceLength + halo) * factor).rounded(.up)
        guard let left = Int(exactly: scaledLeft), let right = Int(exactly: scaledRight),
              right > left, right - left <= 16_384 else {
            throw PAGError.resourceLimitExceeded("fastBlurDimensions")
        }
        self.sourceLength = sourceLength
        self.outputLength = repeatEdgePixels ? sourceLength : sample.partialValue
        self.outputLeft = repeatEdgePixels ? 0 : -halo
        self.sampleLeft = -halo
        self.sampleLength = sample.partialValue
        self.reducedLength = right - left
        self.actualScale = Float(right - left) / Float(sample.partialValue)
        self.kernel = try FeatherGaussianAxis.make(min(sigma, 10))
    }

    /// 缩采附件的像素中心映回原输入坐标，供边缘模式线性采样。
    var sourceTransform: (scale: Float, translate: Float) {
        (1 / actualScale, Float(sampleLeft))
    }

    /// 最终输出像素中心映到缩采卷积结果；Clamp因此裁回原输入范围。
    var outputTransform: (scale: Float, translate: Float) {
        (actualScale, Float(outputLeft - sampleLeft) * actualScale)
    }
}

/// 两轴FastBlur局部附件尺寸；禁止把单轴合法但总面积超预算的帧送入Metal。
struct FastBlurTextureLayout: Sendable {
    /// 水平内部采样、卷积及输出布局。
    let x: FastBlurTextureAxis
    /// 垂直内部采样、卷积及输出布局。
    let y: FastBlurTextureAxis

    /// 用已换算的像素sigma确定有界纹理，透明边缘与Clamp共享缩采核但输出尺寸不同。
    init(_ sampling: FastBlurSampling, width: Int, height: Int) throws {
        x = try FastBlurTextureAxis(sourceLength: width, sigma: sampling.sigmaX,
                                    repeatEdgePixels: sampling.repeatEdgePixels)
        y = try FastBlurTextureAxis(sourceLength: height, sigma: sampling.sigmaY,
                                    repeatEdgePixels: sampling.repeatEdgePixels)
        guard UInt128(x.sampleLength) * UInt128(y.sampleLength) <= 16_777_216,
              UInt128(x.reducedLength) * UInt128(y.reducedLength) <= 16_777_216,
              UInt128(x.outputLength) * UInt128(y.outputLength) <= 16_777_216 else {
            throw PAGError.resourceLimitExceeded("fastBlurDimensions")
        }
    }
}
