/// 与MSL三个float4逐字段对齐的平铺采样常量，不持有图像或显示目标。
struct MetalMotionTileUniforms {
    /// 输入归一化中心及一块纹理相对于输入的宽高。
    let centerAndTile: SIMD4<Float>
    /// 输出相对宽高、正phase度数及水平交错标记。
    let outputAndPhase: SIMD4<Float>
    /// x为奇数块镜像标记，其它分量保留零。
    let mirror: SIMD4<Float>

    /// 将已采样的Double字段窄化为上游Float着色域，无法表示时明确失败。
    init(_ value: FrameMotionTile) throws {
        centerAndTile = SIMD4(Float(value.center.x), Float(value.center.y),
            Float(value.tileWidth) / 100, Float(value.tileHeight) / 100)
        outputAndPhase = SIMD4(Float(value.outputWidth) / 100,
            Float(value.outputHeight) / 100, Float(value.phase),
            value.horizontalPhaseShift ? 1 : 0)
        mirror = SIMD4(value.mirrorEdges ? 1 : 0, 0, 0, 0)
        guard (0..<4).allSatisfy({ centerAndTile[$0].isFinite && outputAndPhase[$0].isFinite }),
              centerAndTile.z > 0, centerAndTile.w > 0,
              outputAndPhase.x > 0, outputAndPhase.y > 0 else {
            throw PAGError.unsupportedFeature("motionTileDimensions")
        }
    }
}

/// MotionTile只改图像取样和输入单位矩形的输出范围，仍由共同Metal根pass绘制。
enum MetalMotionTileGeometry {
    /// 以输入内容矩形中心扩展输出，不把tileCenter错当输出外框中心。
    static func outputMatrix(for image: FrameImage) throws -> SceneAffine {
        guard let tile = image.motionTile else {
            throw PAGError.renderingFailure("missingMotionTile")
        }
        let width = tile.outputWidth / 100, height = tile.outputHeight / 100
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw PAGError.unsupportedFeature("motionTileDimensions")
        }
        let expand = try SceneAffine.scale(x: width, y: height)
            .following(.translation(x: (1 - width) / 2, y: (1 - height) / 2))
        let imagePixels = try SceneAffine.scale(x: image.pixelSize.width, y: image.pixelSize.height)
            .following(image.matrix)
        return try expand.following(imagePixels)
    }
}
