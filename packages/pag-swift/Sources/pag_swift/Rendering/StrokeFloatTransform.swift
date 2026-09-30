/// 只用于源中心线的Float矩阵边界；最终轮廓及Conic近似不能再次经过此量化器。
struct StrokeFloatTransform {
    /// 局部x对目标x的Float系数。
    let a: Float
    /// 局部x对目标y的Float系数。
    let b: Float
    /// 局部y对目标x的Float系数。
    let c: Float
    /// 局部y对目标y的Float系数。
    let d: Float
    /// 目标x的Float平移。
    let tx: Float
    /// 目标y的Float平移。
    let ty: Float

    /// 缓存有限系数，避免逐点重复转换同一个累计矩阵。
    init(_ matrix: SceneAffine) throws {
        a = try StrokeEvaluation.finite(matrix.a)
        b = try StrokeEvaluation.finite(matrix.b)
        c = try StrokeEvaluation.finite(matrix.c)
        d = try StrokeEvaluation.finite(matrix.d)
        tx = try StrokeEvaluation.finite(matrix.tx)
        ty = try StrokeEvaluation.finite(matrix.ty)
    }

    /// 单次Float点变换；调用方分别执行组矩阵与paint逆矩阵，不能合并成Double运算。
    func applying(to point: ScenePoint) throws -> ScenePoint {
        let x = try StrokeEvaluation.finite(point.x), y = try StrokeEvaluation.finite(point.y)
        let resultX = a * x + c * y + tx, resultY = b * x + d * y + ty
        guard resultX.isFinite, resultY.isFinite else { throw SceneValidator.invalid("unrepresentableStrokeTransform") }
        return ScenePoint(x: Double(resultX), y: Double(resultY))
    }
}
