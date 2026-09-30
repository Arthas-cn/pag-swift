import Foundation

/// 求值层使用的有限二维仿射矩阵，列向量约定；不持有 CoreGraphics 或 GPU 对象。
struct SceneAffine: Sendable, Equatable {
    /// 局部 x 对目标 x 的系数，可为零或负。
    let a: Double
    /// 局部 x 对目标 y 的系数。
    let b: Double
    /// 局部 y 对目标 x 的系数。
    let c: Double
    /// 局部 y 对目标 y 的系数，可为零或负。
    let d: Double
    /// 目标坐标中的水平平移。
    let tx: Double
    /// 目标坐标中的垂直平移。
    let ty: Double

    /// 不改变输入点的单位矩阵。
    static let identity = SceneAffine()

    /// 构造单位矩阵，所有常量都可精确表示，不执行浮点计算。
    private init() {
        a = 1
        b = 0
        c = 0
        d = 1
        tx = 0
        ty = 0
    }

    /// 构造有限矩阵；任何非有限系数都表示源求值不可表示，抛 invalidFile。
    init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) throws {
        guard a.isFinite, b.isFinite, c.isFinite, d.isFinite, tx.isFinite, ty.isFinite else {
            throw SceneValidator.invalid("unrepresentableTransform")
        }
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    /// 当前变换后再应用 next，即 next × self；非有限级联结果失败。
    func following(_ next: SceneAffine) throws -> SceneAffine {
        // 上游 Matrix::postConcat 明确左乘；把局部矩阵放前，避免误写成父坐标先变换。
        try SceneAffine(a: next.a * a + next.c * b, b: next.b * a + next.d * b,
                        c: next.a * c + next.c * d, d: next.b * c + next.d * d,
                        tx: next.a * tx + next.c * ty + next.tx,
                        ty: next.b * tx + next.d * ty + next.ty)
    }

    /// 将一个有限局部点映射到目标坐标；输入或运算非有限时失败。
    func applying(to point: ScenePoint) throws -> ScenePoint {
        let x = a * point.x + c * point.y + tx
        let y = b * point.x + d * point.y + ty
        guard x.isFinite, y.isFinite else { throw SceneValidator.invalid("unrepresentableTransform") }
        return ScenePoint(x: x, y: y)
    }

    /// 判断是否有可绘制面积；零行列式不绘制，非有限运算报告源矩阵不可表示。
    func hasArea() throws -> Bool {
        let determinant = a * d - b * c
        guard determinant.isFinite else { throw SceneValidator.invalid("unrepresentableTransform") }
        return determinant != 0
    }

    /// 创建目标坐标中的平移，拒绝非有限偏移。
    static func translation(x: Double, y: Double) throws -> SceneAffine {
        try SceneAffine(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
    }

    /// 创建两轴缩放；零和负值是合法源语义，不能在这里改成单位矩阵。
    static func scale(x: Double, y: Double) throws -> SceneAffine {
        try SceneAffine(a: x, b: 0, c: 0, d: y, tx: 0, ty: 0)
    }

    /// 创建以度为单位的旋转；PAG 向下的 y 轴使正角在画面上顺时针。
    static func rotation(degrees: Double) throws -> SceneAffine {
        let radians = degrees * (.pi / 180)
        let sine = sin(radians)
        let cosine = cos(radians)
        return try SceneAffine(a: cosine, b: sine, c: -sine, d: cosine, tx: 0, ty: 0)
    }

    /// 将共同显示缩放结果作为最后一级仿射映射；裁剪仍由 FramePlan 独立保存。
    init(display: DisplayTransform) {
        a = display.a
        b = display.b
        c = display.c
        d = display.d
        tx = display.tx
        ty = display.ty
    }
}
