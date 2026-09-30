/// 固定TGFX的描边逆矩阵判定；不能复用仅判断Double面积是否为零的fill过滤。
extension StrokeEvaluation {
    /// 按Float矩阵分支求逆；nil表示按源码在layer坐标直接描边，非有限计算与取消明确失败。
    static func inverse(of matrix: SceneAffine) throws -> SceneAffine? {
        try Task.checkCancellation()
        let a = try finite(matrix.a), b = try finite(matrix.b)
        let c = try finite(matrix.c), d = try finite(matrix.d)
        let tx = try finite(matrix.tx), ty = try finite(matrix.ty)
        if b == 0, c == 0 {
            // TGFX纯scale/translate只查单轴是否为零，不套用一般仿射的行列式阈值。
            guard a != 0, d != 0 else { return nil }
            let x: Float = 1 / a, y: Float = 1 / d
            return try checkedMatrix(a: x, b: 0, c: 0, d: y, tx: -tx * x, ty: -ty * y)
        }
        let determinant = a * d - c * b
        guard determinant.isFinite else { throw SceneValidator.invalid("unrepresentableStrokeTransform") }
        guard abs(determinant) > Float(1.0 / 68_719_476_736) else { return nil }
        let scale: Float = 1 / determinant
        return try checkedMatrix(a: d * scale, b: -b * scale, c: -c * scale, d: a * scale,
                                 tx: (c * ty - d * tx) * scale, ty: (b * tx - a * ty) * scale)
    }

    /// 在发布纯值矩阵之前验证全部Float中间结果，不把溢出的逆矩阵误作奇异回落。
    private static func checkedMatrix(a: Float, b: Float, c: Float, d: Float, tx: Float, ty: Float) throws -> SceneAffine {
        guard [a, b, c, d, tx, ty].allSatisfy(\.isFinite) else {
            throw SceneValidator.invalid("unrepresentableStrokeTransform")
        }
        return try SceneAffine(a: Double(a), b: Double(b), c: Double(c), d: Double(d), tx: Double(tx), ty: Double(ty))
    }
}
