/// tag60的原始FastBlur轨道；预合成Glow链与Shape局部滤镜按各自输入域逐帧消费。
struct SourceFastBlur: Sendable {
    /// 送入滤镜前还会乘源/效果尺度的模糊量；零帧按上游visibleAt跳过。
    let blurriness: SourceProperty<Double>
    /// 上游All/Horizontal/Vertical的0/1/2原始离散值。
    let direction: SourceProperty<UInt8>
    /// true用Clamp且保持输入裁剪；false允许透明边缘扩大输出范围。
    let repeatEdgePixels: SourceProperty<Bool>

    /// 在所属合成绝对帧读取全部轨道，避免以初值代替动态效果。
    func value(at frame: Int64) throws -> SampledFastBlur {
        let direction = try PropertyEvaluation.value(direction, at: frame) { keyframe, _ in
            keyframe.startValue
        }
        return SampledFastBlur(blurriness: try PropertyEvaluation.scalar(blurriness, at: frame),
            direction: direction,
            repeatEdgePixels: try PropertyEvaluation.discreteBool(repeatEdgePixels, at: frame))
    }
}

/// 单帧FastBlur源参数；实际Gaussian sigma还需乘滤镜/源内容尺度。
struct SampledFastBlur: Sendable {
    /// 当前帧的原始blurriness，零意味着上游滤镜不可见。
    let blurriness: Double
    /// 取0双轴、1仅水平、2仅垂直。
    let direction: UInt8
    /// 取Clamp或默认透明边缘的原始开关。
    let repeatEdgePixels: Bool
}
