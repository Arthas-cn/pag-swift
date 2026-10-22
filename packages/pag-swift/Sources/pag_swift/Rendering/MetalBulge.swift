/// 与MSL三组float4对应的图像凸出常量；绘制时只读取现有输入纹理。
struct MetalBulgeUniforms {
    /// 输入空间中心和两个正半径。
    let centerAndRadii: SIMD4<Float>
    /// 输出矩形左上角及其宽高，用于将片元单位坐标映回输入域。
    let outputRect: SIMD4<Float>
    /// x为凸出高度，y为pinning开关，其余分量固定零。
    let heightAndPinning: SIMD4<Float>

    /// 已由内部调用点固定的四向量占位值；仅供未启用Bulge的融合材质保持MSL布局。
    init(centerAndRadii: SIMD4<Float>, outputRect: SIMD4<Float>,
         heightAndPinning: SIMD4<Float>) {
        self.centerAndRadii = centerAndRadii
        self.outputRect = outputRect
        self.heightAndPinning = heightAndPinning
    }

    /// 双精度计划转为Metal Float，溢出或非正半径不发布GPU命令。
    init(_ value: FrameBulge) throws {
        centerAndRadii = SIMD4(Float(value.center.x), Float(value.center.y),
            Float(value.radiusX), Float(value.radiusY))
        outputRect = SIMD4(Float(value.outputOrigin.x), Float(value.outputOrigin.y),
            Float(value.outputSize.width), Float(value.outputSize.height))
        heightAndPinning = SIMD4(Float(value.height), value.pinning ? 1 : 0, 0, 0)
        guard (0..<4).allSatisfy({ centerAndRadii[$0].isFinite && outputRect[$0].isFinite }),
              heightAndPinning.x.isFinite,
              centerAndRadii.z > 0, centerAndRadii.w > 0,
              outputRect.z > 0, outputRect.w > 0 else {
            throw PAGError.unsupportedFeature("bulgeDimensions")
        }
    }
}

/// 将Bulge输出矩形映回原图像素与显示矩阵，根pass仍直接使用drawable。
enum MetalBulgeGeometry {
    /// 输出范围在输入纹理空间表达；外层图层和合成矩阵只在末端应用一次。
    static func outputMatrix(for image: FrameImage) throws -> SceneAffine {
        guard let bulge = image.bulge else {
            throw PAGError.renderingFailure("missingBulge")
        }
        let inputOrigin = image.cornerPin?.outputOrigin ?? .zero
        let inputSize = image.cornerPin?.outputSize ?? image.pixelSize
        let output = try SceneAffine.scale(x: bulge.outputSize.width * inputSize.width,
            y: bulge.outputSize.height * inputSize.height)
            .following(.translation(x: inputOrigin.x + bulge.outputOrigin.x * inputSize.width,
                y: inputOrigin.y + bulge.outputOrigin.y * inputSize.height))
        return try output.following(image.matrix)
    }
}
