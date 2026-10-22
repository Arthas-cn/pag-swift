/// 图像层tag56的原始效果轨道；几何和纹理采样由帧计划与Metal共同决定。
struct SourceMotionTile: Sendable {
    /// 图像局部坐标中的平铺中心，空间曲线沿所属合成帧求值。
    let center: SourceProperty<ScenePoint>
    /// 每块横向宽度相对于输入内容的百分数，必须为正。
    let tileWidth: SourceProperty<Double>
    /// 每块纵向高度相对于输入内容的百分数，必须为正。
    let tileHeight: SourceProperty<Double>
    /// 最终平铺区域相对于输入内容的横向百分数，必须为正。
    let outputWidth: SourceProperty<Double>
    /// 最终平铺区域相对于输入内容的纵向百分数，必须为正。
    let outputHeight: SourceProperty<Double>
    /// 奇数块是否镜像其采样坐标。
    let mirrorEdges: SourceProperty<Bool>
    /// 正值以度数沿交错行或列移动纹理采样；非正值不移动。
    let phase: SourceProperty<Double>
    /// true按奇数行横移，false按奇数列纵移。
    let horizontalPhaseShift: SourceProperty<Bool>

    /// 按所属合成帧取得效果数值；不在求值阶段上传纹理或访问drawable。
    func value(at frame: Int64) throws -> SampledMotionTile {
        let value = try SampledMotionTile(center: PropertyEvaluation.point(center, at: frame),
            tileWidth: PropertyEvaluation.scalar(tileWidth, at: frame),
            tileHeight: PropertyEvaluation.scalar(tileHeight, at: frame),
            outputWidth: PropertyEvaluation.scalar(outputWidth, at: frame),
            outputHeight: PropertyEvaluation.scalar(outputHeight, at: frame),
            mirrorEdges: PropertyEvaluation.discreteBool(mirrorEdges, at: frame),
            phase: PropertyEvaluation.scalar(phase, at: frame),
            horizontalPhaseShift: PropertyEvaluation.discreteBool(horizontalPhaseShift, at: frame))
        guard value.tileWidth > 0, value.tileHeight > 0,
              value.outputWidth > 0, value.outputHeight > 0,
              value.phase.isFinite else {
            throw PAGError.unsupportedFeature("motionTileDimensions")
        }
        return value
    }
}

/// 当前帧不含平台对象的MotionTile取值；输入中心仍在图像所属层坐标。
struct SampledMotionTile: Sendable {
    /// 原始图层局部中心，随后按ImagePlacement逆变换归一到实际输入图。
    let center: ScenePoint
    /// 每块横向输入百分数。
    let tileWidth: Double
    /// 每块纵向输入百分数。
    let tileHeight: Double
    /// 输出横向百分数。
    let outputWidth: Double
    /// 输出纵向百分数。
    let outputHeight: Double
    /// 奇数块的镜像开关。
    let mirrorEdges: Bool
    /// 交错移动的源角度。
    let phase: Double
    /// 移动沿行还是列交错。
    let horizontalPhaseShift: Bool
}
