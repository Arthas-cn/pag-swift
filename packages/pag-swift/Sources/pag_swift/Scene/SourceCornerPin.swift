/// tag58四角轨道；按所属层时间取值，源点仍在层局部坐标。
struct SourceCornerPin: Sendable {
    /// 输出四边形的左上角空间轨道。
    let upperLeft: SourceProperty<ScenePoint>
    /// 输出四边形的右上角空间轨道。
    let upperRight: SourceProperty<ScenePoint>
    /// 输出四边形的左下角空间轨道。
    let lowerLeft: SourceProperty<ScenePoint>
    /// 输出四边形的右下角空间轨道。
    let lowerRight: SourceProperty<ScenePoint>

    /// 同一层帧一次取四角；退化与反折检查延至结合真实图片布局时进行。
    func value(at frame: Int64) throws -> SampledCornerPin {
        SampledCornerPin(upperLeft: try PropertyEvaluation.point(upperLeft, at: frame),
            upperRight: try PropertyEvaluation.point(upperRight, at: frame),
            lowerLeft: try PropertyEvaluation.point(lowerLeft, at: frame),
            lowerRight: try PropertyEvaluation.point(lowerRight, at: frame))
    }
}

/// 当前层帧四角值，尚未映回原图像素基准。
struct SampledCornerPin: Sendable {
    /// 当前输出左上角。
    let upperLeft: ScenePoint
    /// 当前输出右上角。
    let upperRight: ScenePoint
    /// 当前输出左下角。
    let lowerLeft: ScenePoint
    /// 当前输出右下角。
    let lowerRight: ScenePoint
}
