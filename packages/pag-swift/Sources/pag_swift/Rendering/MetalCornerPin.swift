/// 与MSL四组float4一致的逆单应；只在已有图像输入的根pass片元读取。
struct MetalCornerPinUniforms {
    /// 四角包围盒原图像素左上与正尺寸。
    let outputRect: SIMD4<Float>
    /// 输出像素点反求前一效果单位纹理坐标的齐次第一行。
    let inverseX: SIMD4<Float>
    /// 齐次第二行。
    let inverseY: SIMD4<Float>
    /// 齐次分母行。
    let inverseW: SIMD4<Float>

    /// 双精度帧计划落到GPU Float；转换后退化不绘制未验证的投影。
    init(_ value: FrameCornerPin) throws {
        outputRect = SIMD4(Float(value.outputOrigin.x), Float(value.outputOrigin.y),
            Float(value.outputSize.width), Float(value.outputSize.height))
        inverseX = SIMD4(Float(value.inverseX.x), Float(value.inverseX.y), Float(value.inverseX.z), 0)
        inverseY = SIMD4(Float(value.inverseY.x), Float(value.inverseY.y), Float(value.inverseY.z), 0)
        inverseW = SIMD4(Float(value.inverseW.x), Float(value.inverseW.y), Float(value.inverseW.z), 0)
        guard (0..<4).allSatisfy({ outputRect[$0].isFinite && inverseX[$0].isFinite &&
                                   inverseY[$0].isFinite && inverseW[$0].isFinite }),
              outputRect.z > 0, outputRect.w > 0 else {
            throw PAGError.unsupportedFeature("cornerPinGeometry")
        }
    }
}

/// 在四角AABB中建立单位矩形的实际显示矩阵，不把输入图像宽高再乘一次。
enum MetalCornerPinGeometry {
    /// 输出范围按原图像素基准与图层矩阵串接；片元会拒绝四角外透明区域。
    static func outputMatrix(for image: FrameImage) throws -> SceneAffine {
        guard let corner = image.cornerPin else {
            throw PAGError.renderingFailure("missingCornerPin")
        }
        let rectangle = try SceneAffine.scale(x: corner.outputSize.width,
            y: corner.outputSize.height)
            .following(.translation(x: corner.outputOrigin.x, y: corner.outputOrigin.y))
        return try rectangle.following(image.matrix)
    }
}
