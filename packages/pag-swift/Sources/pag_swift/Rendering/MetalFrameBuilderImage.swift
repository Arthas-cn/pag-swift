import Metal

/// 图像材质的输入坐标与效果输出几何接线；所有结果仍由共同批次画入当前目标。
extension MetalFrameBuilder {
    /// 输入纹理方向保持顶行在前；MotionTile后的模糊在完整效果域而非WebP采样域求值。
    mutating func image(_ value: FrameImage) throws {
        guard let image = frame.images[value.resourceID], image.size == value.pixelSize else {
            throw PAGError.renderingFailure("metalImageResource")
        }
        guard value.motionBlur == nil || (value.motionTile != nil && value.bulge == nil &&
            value.cornerPin == nil && value.clip == nil) else {
            throw PAGError.unsupportedFeature("motionBlurImageMaterial")
        }
        let texture = try resources.image(image, budget: &budget)
        let mesh = try resources.rectangle(budget: &budget)
        let matrix: SceneAffine
        if value.cornerPin != nil {
            matrix = try value.bulge == nil ? MetalCornerPinGeometry.outputMatrix(for: value) :
                MetalBulgeGeometry.outputMatrix(for: value)
        } else if value.motionTile != nil {
            let tiled = try MetalMotionTileGeometry.outputMatrix(for: value)
            if value.motionBlur != nil {
                matrix = try SceneAffine.scale(x: 1.2, y: 1.2)
                    .following(.translation(x: -0.1, y: -0.1)).following(tiled)
            } else {
                matrix = tiled
            }
        } else if value.bulge != nil {
            matrix = try MetalBulgeGeometry.outputMatrix(for: value)
        } else {
            matrix = try SceneAffine.scale(x: image.size.width, y: image.size.height).following(value.matrix)
        }
        let tile = try value.motionTile.map { try MetalMotionTileUniforms($0) }
        let bulge = try value.bulge.map { try MetalBulgeUniforms($0) }
        let corner = try value.cornerPin.map { try MetalCornerPinUniforms($0) }
        let blur: MetalMotionBlurUniforms?
        if let sampling = value.motionBlur, let tileValue = value.motionTile {
            let sx = tileValue.outputWidth / 100, sy = tileValue.outputHeight / 100
            // 上游先扩完整图像平铺域，再按此范围把相邻矩阵换算成37样本速度。
            let input = try RenderBounds(left: value.pixelSize.width * (1 - sx) / 2,
                top: value.pixelSize.height * (1 - sy) / 2,
                right: value.pixelSize.width * (1 + sx) / 2,
                bottom: value.pixelSize.height * (1 + sy) / 2)
            blur = try MetalMotionBlurUniforms(sampling, inputBounds: input)
        } else {
            blur = nil
        }
        var localClips = clips
        if let clip = value.clip { try localClips.append(clip) }
        let alpha = try MetalDrawUniforms.premultiplied(red: 1, green: 1, blue: 1, alpha: value.opacity)
        try append(mesh: mesh, texture: texture, matrix: matrix, color: alpha,
            clips: localClips, motionTile: tile, bulge: bulge, cornerPin: corner, motionBlur: blur)
    }
}
