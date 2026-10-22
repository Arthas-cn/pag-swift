/// tag85整层渐变叠加的完整源轨道；解码层只保存字段，不把样式分摊到Shape图元。
struct SourceGradientOverlay: Sendable {
    /// 与已合成源图混合的模式；真实LOGO为Normal，其他值须经绘制合同验证。
    let blendMode: SourceProperty<UInt8>
    /// 渐变覆盖的不透明度，0...255；在源alpha裁剪之前应用。
    let opacity: SourceProperty<UInt8>
    /// 独立RGB/alpha色标及其时间轨道，不提前按端点合并。
    let colors: SourceProperty<SourceGradientColors>
    /// 源文件的平滑度参数；当前上游滤镜未消费，仍需完整保留。
    let smoothness: SourceProperty<Double>
    /// 围绕当前局部源图中心旋转的逐帧角度，单位为度。
    let angle: SourceProperty<Double>
    /// 上游GradientFillType数值；真实LOGO为Angle=2。
    let style: SourceProperty<UInt8>
    /// 是否反转色标及梯度方向；当前仅默认false有绘制证明。
    let reverse: SourceProperty<Bool>
    /// 源文件的图层对齐位；当前上游滤镜未消费，仍需完整保留。
    let alignWithLayer: SourceProperty<Bool>
    /// 相对100%的渐变缩放轨道；真实LOGO恒100。
    let scale: SourceProperty<Double>
    /// 相对局部源图宽高百分比的位移轨道；真实LOGO恒零。
    let offset: SourceProperty<ScenePoint>

    /// 真实LOGO的单一Angle白黑样式窄合同；其它字段虽完整读取，尚不能交给当前GPU材质。
    var supportsAngleWhiteBlack: Bool {
        guard !blendMode.isAnimated, blendMode.initialValue == 0,
              !opacity.isAnimated, opacity.initialValue == 255,
              !colors.isAnimated, !smoothness.isAnimated, smoothness.initialValue == 0,
              !style.isAnimated, style.initialValue == 2,
              !reverse.isAnimated, !reverse.initialValue,
              !alignWithLayer.isAnimated, alignWithLayer.initialValue,
              !scale.isAnimated, scale.initialValue == 100,
              !offset.isAnimated, offset.initialValue == .zero else { return false }
        let color = colors.initialValue.colorStops
        let alpha = colors.initialValue.alphaStops
        return color.count == 2 && alpha.count == 2 &&
            color[0].position == 0 && color[1].position == 1 &&
            color[0].midpoint == 0.5 && color[1].midpoint == 0.5 &&
            color[0].color == SceneColor(red: 255, green: 255, blue: 255) &&
            color[1].color == SceneColor(red: 0, green: 0, blue: 0) &&
            alpha[0].position == 0 && alpha[1].position == 1 &&
            alpha[0].midpoint == 0.5 && alpha[1].midpoint == 0.5 &&
            alpha[0].opacity == 255 && alpha[1].opacity == 255
    }
}
