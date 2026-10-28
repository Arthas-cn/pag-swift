@testable import pag_swift

/// 普通蒙版测试的纯语义夹具，不生成或修改完整PAG文件。
enum MaskTestSupport {
    /// 创建可单独控制分支字段的蒙版，默认普通不透明、无扩张；ID不参与几何选择。
    static func mask(_ path: SourceProperty<SourcePath>, mode: SourceMaskMode = .add, inverted: Bool = false,
                     feather: SourceProperty<ScenePoint>? = nil,
                     opacity: SourceProperty<UInt8> = .init(constant: 255),
                     expansion: SourceProperty<Double> = .init(constant: 0)) -> SourceMask {
        SourceMask(id: 0, isInverted: inverted, mode: mode, path: path, feather: feather,
                   opacity: opacity, expansion: expansion)
    }

    /// 用默认帧预算取得内部路径；调用方自行区分nil和没有三角形的有效路径。
    static func sample(_ masks: [SourceMask], at frame: Int64 = 0) throws -> SampledMaskPath? {
        var budget = FramePlanBudget(limit: 64 * 1024 * 1024)
        return try MaskPreparation.singlePath(masks, at: frame, budget: &budget)
    }

    /// 用共同显示精度准备有限路径网格，补集标记不改变网格内容。
    static func mesh(_ path: SourcePath, transform: SceneAffine = .identity) throws -> RenderMesh {
        var budget = try GeometryBudget()
        return try RenderGeometrySource.mask(path).prepare(precision: GeometryPrecision(transform: transform), budget: &budget)
    }
}
