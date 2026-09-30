/// 图层位置的两种源表达；读取后按 LayerTag 规则选择，不能逐帧重新切换模式。
enum SourcePosition: Sendable {
    /// 统一的二维位置，可能具有空间曲线；它优先于同时编码的分离属性。
    case combined(SourceProperty<ScenePoint>)
    /// 编码中二维位置不生效时采用独立 x/y 轨道。
    case separated(x: SourceProperty<Double>, y: SourceProperty<Double>)

    /// 求值当前选定表达；任何分量不可表示时失败。
    func value(at frame: Int64) throws -> ScenePoint {
        switch self {
        case .combined(let point): try PropertyEvaluation.point(point, at: frame)
        case .separated(let x, let y):
            try ScenePoint(x: PropertyEvaluation.scalar(x, at: frame), y: PropertyEvaluation.scalar(y, at: frame))
        }
    }
}

/// 不可变二维变换轨道，与某一帧的 SourceTransform 数值快照分开。
struct SourceTransformProperties: Sendable {
    /// 图层局部锚点；空间属性以 PAG 0.05 精度读取关键帧值。
    let anchor: SourceProperty<ScenePoint>
    /// 读取时已按动画存在性/静态零值决定的组合或分离位置。
    let position: SourcePosition
    /// x/y 可分别缓动的缩放，允许负值和零。
    let scale: SourceProperty<ScenePoint>
    /// 单位为度的旋转轨道。
    let rotation: SourceProperty<Double>
    /// 原始 UInt8 不透明度轨道。
    let opacity: SourceProperty<UInt8>

    /// 从已验证的常量值建立轨道，用于静态语义图和不带动画的内容。
    init(constant: SourceTransform) {
        anchor = SourceProperty(constant: constant.anchor)
        position = .combined(SourceProperty(constant: constant.position))
        scale = SourceProperty(constant: constant.scale)
        rotation = SourceProperty(constant: constant.rotation)
        opacity = SourceProperty(constant: constant.opacity)
    }

    /// 安装解码器已经完成验证的轨道；不生成首帧占位变换。
    init(anchor: SourceProperty<ScenePoint>, position: SourcePosition, scale: SourceProperty<ScenePoint>,
         rotation: SourceProperty<Double>, opacity: SourceProperty<UInt8>) {
        self.anchor = anchor
        self.position = position
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
    }

    /// 在所属合成的帧坐标求值得到完整数值，供同一矩阵核心使用。
    func value(at frame: Int64) throws -> SourceTransform {
        try SourceTransform(anchor: PropertyEvaluation.point(anchor, at: frame), position: position.value(at: frame),
                            scale: PropertyEvaluation.point(scale, at: frame), rotation: PropertyEvaluation.scalar(rotation, at: frame),
                            opacity: PropertyEvaluation.opacity(opacity, at: frame))
    }
}
