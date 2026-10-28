/// tag61的源轨道；只保存上游字段，不把尚未接通的GPU效果误认为可播放。
struct SourceGlow: Sendable {
    /// Merge滤镜的RGB除数，可随所属合成帧变化。
    let threshold: SourceProperty<Double>
    /// 横向Blur滤镜的缩放半径，可随所属合成帧变化。
    let radius: SourceProperty<Double>
    /// 原始强度轨道；当前上游GlowFilter::Apply未消费它，仍需完整保存。
    let intensity: SourceProperty<Double>

    /// 按所属合成帧求出三项值；非有限值留给调用方明确拒绝。
    func value(at frame: Int64) throws -> SampledGlow {
        SampledGlow(threshold: try PropertyEvaluation.scalar(threshold, at: frame),
                    radius: try PropertyEvaluation.scalar(radius, at: frame),
                    intensity: try PropertyEvaluation.scalar(intensity, at: frame))
    }
}

/// 单帧Glow数值；尚未映射到输入纹理尺寸或GPU局部附件。
struct SampledGlow: Sendable {
    /// 原内容与模糊内容逐通道取大后的除数。
    let threshold: Double
    /// 第一次滤镜的输入尺寸缩减量，单位为源效果参数。
    let radius: Double
    /// 已完整读取但当前上游应用函数尚未参与着色的源值。
    let intensity: Double
}
