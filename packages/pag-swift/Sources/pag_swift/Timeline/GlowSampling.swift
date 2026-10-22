/// Glow两轴滤镜的纯值尺寸与UV步长；保留完整输入域，不能拿紧致内容附件的尺寸代替。
struct GlowSampling: Sendable {
    /// 滤镜开始时的完整整数宽度；局部附件不能修改其语义。
    let inputWidth: UInt32
    /// 滤镜开始时的完整整数高度。
    let inputHeight: UInt32
    /// 横轴滤镜输出的整数宽度，也是纵轴滤镜的输入宽度。
    let blurWidth: UInt32
    /// 横轴滤镜输出的整数高度，也是纵轴滤镜的输入高度。
    let blurHeight: UInt32
    /// 横轴五点核的归一化单位步长，依据缩小后的完整语义宽度。
    let horizontalStep: Float
    /// 纵轴五点核的归一化单位步长，依据缩小后的完整语义高度。
    let verticalStep: Float
    /// Merge片元使用的逐通道RGB除数。
    let threshold: Float
    /// 读取但不注入滤镜的强度；对应上游当前Apply函数的实际消费行为。
    let intensity: Float

    /// 从原始整数输入域建立滤镜尺寸；无效或超出GPU可表示范围时明确失败。
    init(_ glow: SampledGlow, inputWidth: Int, inputHeight: Int) throws {
        let radius = Float(glow.radius)
        let threshold = Float(glow.threshold)
        let intensity = Float(glow.intensity)
        let ratio = 1 - radius / 1500
        guard inputWidth > 0, inputHeight > 0, ratio.isFinite, ratio > 0,
              threshold.isFinite, intensity.isFinite else {
            throw PAGError.unsupportedFeature("glowDimensions")
        }
        let width = (Float(inputWidth) * ratio).rounded(.up)
        let height = (Float(inputHeight) * ratio).rounded(.up)
        guard let inputWidth = UInt32(exactly: inputWidth), let inputHeight = UInt32(exactly: inputHeight),
              let blurWidth = UInt32(exactly: width), let blurHeight = UInt32(exactly: height),
              blurWidth > 0, blurHeight > 0 else {
            throw PAGError.unsupportedFeature("glowDimensions")
        }
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.blurWidth = blurWidth
        self.blurHeight = blurHeight
        self.horizontalStep = 1 / Float(blurWidth)
        self.verticalStep = 1 / Float(blurHeight)
        self.threshold = threshold
        self.intensity = intensity
    }
}
