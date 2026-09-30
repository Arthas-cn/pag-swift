/// 一次描边paint的纯值坐标信息，供后台中心线和outline消费；不持有平台路径。
struct ShapeStroke: Sendable, Equatable {
    /// 已完成属性求值的几何样式，不包含颜色或alpha。
    let style: StrokeStyle
    /// Float量化后的paint累计组矩阵，逆变换成功后用于复原outline。
    let matrix: SceneAffine
    /// nil表示逆失败，按源码在图层坐标直接描边且不复原奇异矩阵。
    let inverse: SceneAffine?

    /// 固定Float边界和逆判定；不能把轮廓变换与paint逆变换提前合并为Double矩阵。
    init(style: StrokeStyle, matrix: SceneAffine) throws {
        self.style = style
        self.matrix = try SceneAffine(a: Double(StrokeEvaluation.finite(matrix.a)), b: Double(StrokeEvaluation.finite(matrix.b)),
            c: Double(StrokeEvaluation.finite(matrix.c)), d: Double(StrokeEvaluation.finite(matrix.d)),
            tx: Double(StrokeEvaluation.finite(matrix.tx)), ty: Double(StrokeEvaluation.finite(matrix.ty)))
        inverse = try StrokeEvaluation.inverse(of: self.matrix)
    }

    /// 实际描边后应应用的复原矩阵；逆失败不再重复应用原奇异矩阵。
    var restoration: SceneAffine { inverse == nil ? .identity : matrix }
}
