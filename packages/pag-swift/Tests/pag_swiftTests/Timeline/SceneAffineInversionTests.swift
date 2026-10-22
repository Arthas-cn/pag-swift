import Testing
@testable import pag_swift

/// Vector局部纹理所需的显示逆映射，覆盖旋转、非1倍率和不可逆源矩阵。
struct SceneAffineInversionTests {
    /// 旋转并缩放后的四个局部点往返应恢复原坐标，平移必须跟线性部分一起求逆。
    @Test func rotatedScaledTranslationRoundTripsPoints() throws {
        let matrix = try SceneAffine.scale(x: -1.5, y: 2.25)
            .following(.rotation(degrees: 37))
            .following(.translation(x: 42, y: -19))
        let inverse = try matrix.inverted()
        for point in [ScenePoint.zero, ScenePoint(x: 1, y: 2),
                      ScenePoint(x: -20, y: 9), ScenePoint(x: 400, y: -150)] {
            let restored = try inverse.applying(to: matrix.applying(to: point))
            #expect(abs(restored.x - point.x) < 1e-9)
            #expect(abs(restored.y - point.y) < 1e-9)
        }
    }

    /// 零行列式不能伪造单位逆矩阵，否则父Picture会把原始图元错误映入局部纹理。
    @Test func singularMatrixFailsClearly() throws {
        let singular = try SceneAffine.scale(x: 0, y: 2)
        #expect(throws: PAGError.renderingFailure("metalPictureInverseTransform")) {
            try singular.inverted()
        }
    }
}
