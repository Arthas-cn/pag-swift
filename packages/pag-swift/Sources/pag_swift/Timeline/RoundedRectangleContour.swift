/// 源Rectangle的解析中心线边界；保留零尺寸和奇异组矩阵，是否有填充面积由绘制消费者判断。
struct RoundedRectangleContour: Sendable, Equatable {
    /// 按Float MakeXYWH求值并排序后的左边界。
    let left: Double
    /// 已排序的上边界，允许等于bottom。
    let top: Double
    /// 已排序的右边界，允许等于left。
    let right: Double
    /// 已排序的下边界。
    let bottom: Double
    /// Float来源的非负统一圆角，零尺寸边界固定为零。
    let radius: Double
    /// 源反向标志，负尺寸和反射矩阵不额外改变它。
    let reversed: Bool
    /// 矩形局部坐标到形状图层的累计组矩阵。
    let matrix: SceneAffine

    /// 已排序边界的中心，仅供查询；构造路径仍使用保存的四条边。
    var center: ScenePoint { ScenePoint(x: left * 0.5 + right * 0.5, y: top * 0.5 + bottom * 0.5) }

    /// 允许零的内部尺寸；公开PAGSize仍要求正宽高。
    var size: ScenePoint { ScenePoint(x: right - left, y: bottom - top) }

    /// 两轴均有跨度才可能产生fill面积；零跨度仍可被描边消费。
    var hasArea: Bool { right > left && bottom > top }

    /// 依次复现RectangleToPath与SkRRect.setRectXY；非有限Float运算失败，不删除退化中心线。
    static func make(size: ScenePoint, position: ScenePoint, roundness: Double, reversed: Bool,
                     matrix: SceneAffine) throws -> RoundedRectangleContour {
        try Task.checkCancellation()
        let width = Float(size.x), height = Float(size.y), x = Float(position.x), y = Float(position.y)
        var radius = Float(roundness)
        guard [width, height, x, y, radius].allSatisfy(\.isFinite) else {
            throw SceneValidator.invalid("unrepresentableShapeGeometry")
        }
        // 源码先按有符号尺寸限半径，再MakeXYWH，最后排序；不能提前abs尺寸或用center±half替换。
        radius = min(radius, width * 0.5, height * 0.5)
        let x0 = x - width * 0.5, y0 = y - height * 0.5
        let x1 = x0 + width, y1 = y0 + height
        guard [x0, x1, y0, y1].allSatisfy(\.isFinite) else {
            throw SceneValidator.invalid("unrepresentableShapeGeometry")
        }
        let left = min(x0, x1), right = max(x0, x1), top = min(y0, y1), bottom = max(y0, y1)
        let spanX = right - left, spanY = bottom - top
        guard spanX.isFinite, spanY.isFinite else { throw SceneValidator.invalid("unrepresentableShapeGeometry") }
        if spanX == 0 || spanY == 0 || radius <= 0 {
            radius = 0
        } else if spanX < radius + radius || spanY < radius + radius {
            // 实际Float边长可能受大原点舍入影响，SkRRect会再次同比例收紧两轴半径。
            radius *= min(spanX / (radius + radius), spanY / (radius + radius))
        }
        let result = RoundedRectangleContour(left: Double(left), top: Double(top), right: Double(right), bottom: Double(bottom),
                                             radius: Double(radius), reversed: reversed, matrix: matrix)
        for point in [ScenePoint(x: result.left, y: result.top), ScenePoint(x: result.right, y: result.top),
                      ScenePoint(x: result.right, y: result.bottom), ScenePoint(x: result.left, y: result.bottom)] {
            _ = try matrix.applying(to: point)
        }
        return result
    }
}
