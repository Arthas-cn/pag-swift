/// 源addCircle/addOval的局部Float轮廓，只合入描边复合路径，不创建独立绘制图元。
enum StrokeCuspContour {
    /// 正半径的尖点圆以四段源conic构建；增长/幅度/取消失败向整次outline传播。
    static func make(center: SIMD2<Float>, radius: Float, output: StrokePathOutput) throws -> StrokeLineBoundary {
        try output.budget.consume()
        guard radius.isFinite, radius > 0 else { throw PAGError.invalidArgument("strokeCuspRadius") }
        let left = center.x - radius, right = center.x + radius
        let top = center.y - radius, bottom = center.y + radius
        guard left.isFinite, right.isFinite, top.isFinite, bottom.isFinite else {
            throw PAGError.resourceLimitExceeded("geometryPrecision")
        }
        // addOval先从圆的Float四边重新计算中心；原center可能与这个结果差一ULP。
        let x = left * 0.5 + right * 0.5, y = top * 0.5 + bottom * 0.5
        try output.budget.reserve(stride: 96)
        let boundary = StrokeLineBoundary()
        try boundary.move(to: SIMD2(right, y), output: output)
        let weight = Float(0.707106781)
        try boundary.append(to: SIMD2(x, bottom), control: SIMD2(right, bottom), weight: weight, output: output)
        try boundary.append(to: SIMD2(left, y), control: SIMD2(left, bottom), weight: weight, output: output)
        try boundary.append(to: SIMD2(x, top), control: SIMD2(left, top), weight: weight, output: output)
        try boundary.append(to: SIMD2(right, y), control: SIMD2(right, top), weight: weight, output: output)
        return boundary
    }
}
