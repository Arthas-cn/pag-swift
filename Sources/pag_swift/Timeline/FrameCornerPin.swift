/// 四角输出在原图像素坐标中的凸四边形及其逆单应；不持有GPU资源。
struct FrameCornerPin: Sendable {
    /// 输出四角轴对齐包围盒左上角，仍在原图像素基准。
    let outputOrigin: ScenePoint
    /// 四角包围盒正尺寸；实际覆盖由逆投影逐片元限定。
    let outputSize: PAGSize
    /// 输出像素点到前一效果单位纹理坐标的齐次逆映射第一行。
    let inverseX: SIMD3<Double>
    /// 齐次逆映射第二行。
    let inverseY: SIMD3<Double>
    /// 齐次逆映射分母行；零或非有限结果不能画。
    let inverseW: SIMD3<Double>

    /// 将层局部四角逆映到原图像素基准，只接纳同向凸且非退化的投影。
    init(_ sampled: SampledCornerPin, placement: SceneAffine) throws {
        let inverse = try placement.inverted()
        let ul = try inverse.applying(to: sampled.upperLeft)
        let ur = try inverse.applying(to: sampled.upperRight)
        let ll = try inverse.applying(to: sampled.lowerLeft)
        let lr = try inverse.applying(to: sampled.lowerRight)
        let points = [ul, ur, lr, ll]
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw PAGError.unsupportedFeature("cornerPinGeometry")
        }
        let left = points.map(\.x).min()!, right = points.map(\.x).max()!
        let top = points.map(\.y).min()!, bottom = points.map(\.y).max()!
        let extent = max(right - left, bottom - top)
        let epsilon = max(1e-9, extent * extent * 1e-10)
        guard extent.isFinite, extent > 0 else {
            throw PAGError.unsupportedFeature("cornerPinGeometry")
        }
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % 4], c = points[(index + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard cross.isFinite, cross > epsilon else {
                throw PAGError.unsupportedFeature("cornerPinGeometry")
            }
        }
        outputOrigin = ScenePoint(x: left, y: top)
        outputSize = try PAGSize(width: right - left, height: bottom - top)

        // 四点映射的射影解严格复用上游对角线q的正常凸四边形分支。
        let dx1 = ur.x - lr.x, dx2 = ll.x - lr.x
        let dy1 = ur.y - lr.y, dy2 = ll.y - lr.y
        let dx3 = ul.x - ur.x + lr.x - ll.x
        let dy3 = ul.y - ur.y + lr.y - ll.y
        let g: Double, h: Double
        if abs(dx3) + abs(dy3) <= epsilon {
            g = 0; h = 0
        } else {
            let denominator = dx1 * dy2 - dx2 * dy1
            guard denominator.isFinite, abs(denominator) > epsilon else {
                throw PAGError.unsupportedFeature("cornerPinGeometry")
            }
            g = (dx3 * dy2 - dx2 * dy3) / denominator
            h = (dx1 * dy3 - dx3 * dy1) / denominator
        }
        let a = ur.x - ul.x + g * ur.x
        let b = ll.x - ul.x + h * ll.x
        let c = ul.x
        let d = ur.y - ul.y + g * ur.y
        let e = ll.y - ul.y + h * ll.y
        let f = ul.y
        let A = e - f * h, B = c * h - b, C = b * f - c * e
        let D = f * g - d, E = a - c * g, F = c * d - a * f
        let G = d * h - e * g, H = b * g - a * h, I = a * e - b * d
        let determinant = a * A + b * D + c * G
        guard determinant.isFinite, abs(determinant) > epsilon else {
            throw PAGError.unsupportedFeature("cornerPinGeometry")
        }
        inverseX = SIMD3(A, B, C) / determinant
        inverseY = SIMD3(D, E, F) / determinant
        inverseW = SIMD3(G, H, I) / determinant
        guard (0..<3).allSatisfy({ inverseX[$0].isFinite && inverseY[$0].isFinite && inverseW[$0].isFinite }) else {
            throw PAGError.unsupportedFeature("cornerPinGeometry")
        }
    }
}
