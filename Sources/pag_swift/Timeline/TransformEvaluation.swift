import Foundation

/// 某一时刻已求值的局部矩阵和自身透明度，不把父控制层透明度混入。
struct EvaluatedTransform: Sendable, Equatable {
    /// 从图层局部坐标到所在合成的有限仿射矩阵。
    let matrix: SceneAffine
    /// 当前层或形状组自身的不透明度，范围 0...1。
    let opacity: Double

    /// 沿控制层父链组合矩阵，自身 opacity 保持不变；溢出时失败。
    func followingParent(_ parent: EvaluatedTransform) throws -> EvaluatedTransform {
        // TransformCache::createCache 只 postConcat parentTransform.matrix，没有乘 parent alpha。
        EvaluatedTransform(matrix: try matrix.following(parent.matrix), opacity: opacity)
    }
}

/// 根据已读取的属性值构造矩阵；不读取文件、不推进时间，也不决定图层是否可见。
enum TransformEvaluation {
    /// 按 RenderTransform 的 anchor → scale → rotation → position 顺序计算当前时刻的图层变换。
    static func layer(_ source: SourceTransform) throws -> EvaluatedTransform {
        let matrix = try anchoredScale(source)
            .following(.rotation(degrees: source.rotation))
            .following(.translation(x: source.position.x, y: source.position.y))
        return EvaluatedTransform(matrix: matrix, opacity: Double(source.opacity) / 255)
    }

    /// 形状组在缩放后旋转前应用轴向斜切，保留源负号及轴方向。
    static func shape(_ source: SourceShapeTransform) throws -> EvaluatedTransform {
        var matrix = try anchoredScale(source.base)
        if source.skew != 0 {
            // ShapeRenderer::SkewFromAxis 依次 R(axis)、K(-skew)、R(-axis)，每次 postConcat 都是左乘。
            let tangent = tan(-source.skew * (.pi / 180))
            let shear = try SceneAffine(a: 1, b: 0, c: tangent, d: 1, tx: 0, ty: 0)
            matrix = try matrix.following(.rotation(degrees: source.skewAxis))
                .following(shear)
                .following(.rotation(degrees: -source.skewAxis))
        }
        matrix = try matrix.following(.rotation(degrees: source.base.rotation))
            .following(.translation(x: source.base.position.x, y: source.base.position.y))
        return EvaluatedTransform(matrix: matrix, opacity: Double(source.base.opacity) / 255)
    }

    /// 图层和形状共享的前两步；锚点须先平移再缩放，否则旋转中心会移动。
    private static func anchoredScale(_ source: SourceTransform) throws -> SceneAffine {
        try SceneAffine.translation(x: -source.anchor.x, y: -source.anchor.y)
            .following(.scale(x: source.scale.x, y: source.scale.y))
    }
}
