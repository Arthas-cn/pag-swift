/// 形状组的不可变属性轨道；只保存源合成时间，不持有界面或逐帧缓存。
struct SourceShapeTransformProperties: Sendable {
    /// 局部锚点的Spatial轨道；缺省为原点。
    let anchor: SourceProperty<ScenePoint>
    /// 父坐标系位置的Spatial轨道，不采用图层的分离x/y规则。
    let position: SourceProperty<ScenePoint>
    /// 两轴独立时间缓动的缩放；负值和零合法。
    let scale: SourceProperty<ScenePoint>
    /// 斜切角度轨道，单位为度。
    let skew: SourceProperty<Double>
    /// 斜切轴角度轨道，单位为度。
    let skewAxis: SourceProperty<Double>
    /// 旋转角度轨道，单位为度。
    let rotation: SourceProperty<Double>
    /// 整组不透明度轨道，0完全透明、255完全不透明。
    let opacity: SourceProperty<UInt8>

    /// 自身任一轨道含关键帧即为动画，不依据初值或子元素判断。
    var isAnimated: Bool {
        anchor.isAnimated || position.isAnimated || scale.isAnimated || skew.isAnimated ||
            skewAxis.isAnimated || rotation.isAnimated || opacity.isAnimated
    }

    /// 在源合成帧求值完整变换；取消或数值不可表示时抛错，不再次减图层起点。
    func value(at frame: Int64) throws -> SourceShapeTransform {
        try Task.checkCancellation()
        return try SourceShapeTransform(
            base: SourceTransform(anchor: PropertyEvaluation.point(anchor, at: frame),
                                  position: PropertyEvaluation.point(position, at: frame),
                                  scale: PropertyEvaluation.point(scale, at: frame),
                                  rotation: PropertyEvaluation.scalar(rotation, at: frame),
                                  opacity: PropertyEvaluation.opacity(opacity, at: frame)),
            skew: PropertyEvaluation.scalar(skew, at: frame),
            skewAxis: PropertyEvaluation.scalar(skewAxis, at: frame))
    }
}

/// 矩形的源属性；逐帧数值由准备层交给既有圆角矩形几何核心。
struct SourceRectangle: Sendable {
    /// 文件BitFlag决定的反向绕序，不随时间变化。
    let reversed: Bool
    /// 两轴独立缓动的尺寸；保留源负值和零值。
    let size: SourceProperty<ScenePoint>
    /// 矩形中心的Spatial位置轨道。
    let position: SourceProperty<ScenePoint>
    /// 圆角半径轨道；半宽、半高限制在几何求值时处理。
    let roundness: SourceProperty<Double>

    /// 尺寸、中心或圆角含关键帧即为动画，包括初值为默认值的轨道。
    var isAnimated: Bool { size.isAnimated || position.isAnimated || roundness.isAnimated }
}

/// 普通混合、Below顺序、NonZero填充的源轨道，不扩充其他填充语义。
struct SourceFill: Sendable {
    /// 三个RGB字节共用一套时间缓动；缺省色是Red。
    let color: SourceProperty<SceneColor>
    /// 独立不透明度轨道；零值只跳过paint，不清空累计路径。
    let opacity: SourceProperty<UInt8>

    /// 颜色或不透明度含关键帧即为动画，透明首帧不能降为静态。
    var isAnimated: Bool { color.isAnimated || opacity.isAnimated }
}
