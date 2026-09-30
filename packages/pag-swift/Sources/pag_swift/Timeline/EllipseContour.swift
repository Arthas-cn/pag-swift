/// Ellipse的未排序Float边界；只保存采样描述值，实际Conic在后台网格缺失时才生成。
struct EllipseContour: Sendable, Equatable {
    /// 源MakeXYWH计算的左边，可以大于right，不能排序。
    let left: Float
    /// 源计算的上边，可以大于bottom。
    let top: Float
    /// Float的left+width，保留大原点处舍入。
    let right: Float
    /// Float的top+height，零尺寸也保留。
    let bottom: Float
    /// 源反向标志，负尺寸不额外翻转此值。
    let reversed: Bool
    /// 局部路径到图层的完整组矩阵，不在缓存匹配时省略。
    let matrix: SceneAffine

    /// 在源合成帧求尺寸和中心；保留Float运算顺序，非有限结果或取消不返回轮廓。
    static func make(_ source: SourceEllipse, at frame: Int64, matrix: SceneAffine) throws -> Self {
        try Task.checkCancellation()
        let size = try PropertyEvaluation.point(source.size, at: frame)
        let position = try PropertyEvaluation.point(source.position, at: frame)
        let width = Float(size.x), height = Float(size.y), x = Float(position.x), y = Float(position.y)
        guard [width, height, x, y].allSatisfy(\.isFinite) else {
            throw PAGError.resourceLimitExceeded("geometryPrecision")
        }
        // EllipseToPath不走SkRRect排序；右下边必须由已舍入的左上边加源尺寸得到。
        let left = x - width * 0.5, top = y - height * 0.5
        let right = left + width, bottom = top + height
        guard [left, top, right, bottom].allSatisfy(\.isFinite) else {
            throw PAGError.resourceLimitExceeded("geometryPrecision")
        }
        for (x, y) in [(left, top), (right, top), (right, bottom), (left, bottom)] {
            _ = try matrix.applying(to: ScenePoint(x: Double(x), y: Double(y)))
        }
        return Self(left: left, top: top, right: right, bottom: bottom, reversed: source.reversed, matrix: matrix)
    }
}
