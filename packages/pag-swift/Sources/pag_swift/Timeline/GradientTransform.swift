/// 渐变布局的最终数学分支；退化仍保留完整未预乘RGBA，不能塞进只有RGB的SceneColor。
enum GradientLayout: Sendable {
    /// 单色或几何退化，忽略解析不可用状态和paint逆矩阵。
    case solid(SIMD4<Float>)
    /// 从网格重定位坐标到渐变单位坐标的有限Float复合矩阵。
    case mapped(GradientTransform)
}

/// TGFX算序的Float仿射映射；只处理渐变采样数学，不改变既有几何/coverage坐标。
struct GradientTransform: Sendable, Equatable {
    /// 输入x对单位x的系数。
    let a: Float
    /// 输入x对单位y的系数。
    let b: Float
    /// 输入y对单位x的系数。
    let c: Float
    /// 输入y对单位y的系数。
    let d: Float
    /// 单位x的平移，可能已包含网格origin补偿。
    let tx: Float
    /// 单位y的平移，可能已包含网格origin补偿。
    let ty: Float

    /// 建立有限Float矩阵；非有限值统一报gradientPrecision，不回落到单位变换。
    init(a: Float, b: Float = 0, c: Float = 0, d: Float, tx: Float = 0, ty: Float = 0) throws {
        guard a.isFinite, b.isFinite, c.isFinite, d.isFinite, tx.isFinite, ty.isFinite else {
            throw PAGError.renderingFailure("gradientPrecision")
        }
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    /// 先判一色与长度退化，再要求解析程序与可逆paint；失败不能提交部分GPU常量。
    static func layout(for gradient: PreparedGradient, origin: ScenePoint = .zero) throws -> GradientLayout {
        try Task.checkCancellation()
        if case .singleColor = gradient.colorizer.result { return .solid(gradient.colorizer.first) }
        let sx = Float(gradient.start.x), sy = Float(gradient.start.y)
        let ex = Float(gradient.end.x), ey = Float(gradient.end.y)
        guard sx.isFinite, sy.isFinite, ex.isFinite, ey.isFinite else {
            throw PAGError.renderingFailure("gradientPrecision")
        }
        let dx = ex - sx, dy = ey - sy
        // Point::Length使用Float平方和再sqrt；不能用Double/hypot让源Float溢出悄悄成功。
        let length = (dx * dx + dy * dy).squareRoot()
        guard length.isFinite else { throw PAGError.renderingFailure("gradientPrecision") }
        if length <= Float(1) / 32768 {
            return .solid(gradient.kind == .linear ? gradient.colorizer.first : gradient.colorizer.last)
        }
        switch gradient.colorizer.result {
        case .analytic: break
        case .requiresTexture: throw PAGError.unsupportedFeature("gradientTextureColorizer")
        case .invalidPrecision: throw PAGError.renderingFailure("gradientPrecision")
        case .singleColor: return .solid(gradient.colorizer.first)
        }
        let unit = try pointsToUnit(kind: gradient.kind, sx: sx, sy: sy, dx: dx, dy: dy, length: length)
        let inverse: SceneAffine?
        do { inverse = try StrokeEvaluation.inverse(of: gradient.matrix) }
        catch is PAGError {
            // 只复用Stroke的Float逆核；数值失败换成渐变错误，取消仍原样向上传播。
            throw PAGError.renderingFailure("gradientPrecision")
        }
        guard let inverse else { throw PAGError.renderingFailure("gradientTransform") }
        let paintInverse = try GradientTransform(a: Float(inverse.a), b: Float(inverse.b), c: Float(inverse.c),
            d: Float(inverse.d), tx: Float(inverse.tx), ty: Float(inverse.ty))
        let combined = try unit.concatenating(paintInverse)
        try Task.checkCancellation()
        return .mapped(try combined.compensating(origin: origin))
    }

    /// 返回self*second，保持Matrix::setConcat初始化后+=的Float次序及纯scale分支。
    func concatenating(_ second: GradientTransform) throws -> GradientTransform {
        if isIdentity { return second }
        if second.isIdentity { return self }
        var sx = second.a * a, sy = second.d * d
        var x = second.tx * a + tx, y = second.ty * d + ty
        var kx: Float = 0, ky: Float = 0
        if b != 0 || c != 0 || second.b != 0 || second.c != 0 {
            sx += second.b * c
            sy += second.c * b
            ky += second.a * b + second.b * d
            kx += second.c * a + second.d * c
            x += second.ty * c
            y += second.tx * b
        }
        return try GradientTransform(a: sx, b: ky, c: kx, d: sy, tx: x, ty: y)
    }

    /// 先保留Float C，再在Double做C*T(origin)平移补偿并一次转Float；这是本库网格重定位政策。
    func compensating(origin: ScenePoint) throws -> GradientTransform {
        let x = Double(a) * origin.x + Double(c) * origin.y + Double(tx)
        let y = Double(b) * origin.x + Double(d) * origin.y + Double(ty)
        return try GradientTransform(a: a, b: b, c: c, d: d, tx: Float(x), ty: Float(y))
    }

    /// 精确单位矩阵，不用近似判断跳过源Float运算。
    private var isIdentity: Bool { a == 1 && b == 0 && c == 0 && d == 1 && tx == 0 && ty == 0 }

    /// Linear的setSinCos→postTranslate→postScale或Radial的translate→postScale，不能化简重排平移。
    private static func pointsToUnit(kind: SourceGradientKind, sx: Float, sy: Float,
                                     dx: Float, dy: Float, length: Float) throws -> GradientTransform {
        let reciprocal: Float = 1 / length
        let base: GradientTransform
        if kind == .linear {
            let u = dx * reciprocal, v = dy * reciprocal, m = 1 - u
            var x = -v * sy + m * sx, y = v * sx + m * sy
            x += -sx
            y += -sy
            base = try GradientTransform(a: u, b: -v, c: v, d: u, tx: x, ty: y)
        } else {
            base = try GradientTransform(a: 1, d: 1, tx: -sx, ty: -sy)
        }
        return try GradientTransform(a: reciprocal, d: reciprocal).concatenating(base)
    }
}
