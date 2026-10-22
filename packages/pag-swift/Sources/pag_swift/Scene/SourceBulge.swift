/// tag59图像凸出效果的源属性；没有平台资源，保留动画轨道供所属合成帧采样。
struct SourceBulge: Sendable {
    /// 输入图像局部坐标中的水平作用半径。
    let horizontalRadius: SourceProperty<Double>
    /// 输入图像局部坐标中的垂直作用半径。
    let verticalRadius: SourceProperty<Double>
    /// 空间曲线描述的凸出中心，按所属合成帧求值。
    let center: SourceProperty<ScenePoint>
    /// 上游滤镜使用的位移高度；零表示此帧效果不可见。
    let height: SourceProperty<Double>
    /// 原始taper字段；当前上游BulgeFilter不消费，但解析身份仍保留。
    let taperRadius: SourceProperty<Double>
    /// 是否把效果取样限制在输入纹理内。
    let pinning: SourceProperty<Bool>

    /// 采样当前帧的几何；不可见帧返回nil，负半径和非有限输入明确拒绝。
    func value(at frame: Int64) throws -> SampledBulge? {
        let horizontal = try PropertyEvaluation.scalar(horizontalRadius, at: frame)
        let vertical = try PropertyEvaluation.scalar(verticalRadius, at: frame)
        let height = try PropertyEvaluation.scalar(height, at: frame)
        guard horizontal.isFinite, vertical.isFinite, height.isFinite else {
            throw PAGError.unsupportedFeature("bulgeDimensions")
        }
        // 源visibleAt只看高度与双半径是否为零；不创建无效效果绘制。
        guard horizontal != 0, vertical != 0, height != 0 else { return nil }
        guard horizontal > 0, vertical > 0 else {
            throw PAGError.unsupportedFeature("bulgeDimensions")
        }
        return SampledBulge(horizontalRadius: horizontal, verticalRadius: vertical,
            center: try PropertyEvaluation.point(center, at: frame), height: height,
            pinning: try PropertyEvaluation.discreteBool(pinning, at: frame))
    }
}

/// 当前帧的Bulge输入空间参数；ImagePlacement还未逆映，不能直接传给Metal。
struct SampledBulge: Sendable {
    /// 所属图像层的局部水平半径。
    let horizontalRadius: Double
    /// 所属图像层的局部垂直半径。
    let verticalRadius: Double
    /// 所属图像层的局部中心。
    let center: ScenePoint
    /// 上游着色器的凸出位移参数。
    let height: Double
    /// 是否钳制源纹理边缘。
    let pinning: Bool
}
