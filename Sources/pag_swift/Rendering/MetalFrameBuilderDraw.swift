import Metal

/// 单个材质绘制的共同预算、裁剪和遮罩组装；不创建额外表面。
extension MetalFrameBuilder {
    /// 为一个完整绘制预留常量/裁剪成本，使用CPU双精度补回网格原点。
    mutating func append(mesh: MetalMesh, texture: (any MTLTexture)?, matrix: SceneAffine,
                                 color: SIMD4<Float>, clips: MetalClipValues, video: MetalVideoInput? = nil,
                                 gradient: PreparedGradient? = nil,
                                 inheritedMask: MetalMaskInput? = nil,
                                 featherMaskTexture: (any MTLTexture)? = nil,
                                 trackMatteMode: SourceTrackMatteType? = nil,
                                 isShadow: Bool = false,
                                 motionTile: MetalMotionTileUniforms? = nil,
                                 bulge: MetalBulgeUniforms? = nil,
                                 cornerPin: MetalCornerPinUniforms? = nil,
                                 textBulgeMap: MetalTextBulgeMap? = nil,
                                 screenBlend: Bool = false, levelsGreenOnly: Bool = false,
                                 hardLightBlend: Bool = false,
                                 motionBlur: MetalMotionBlurUniforms? = nil,
                                 glow: MetalGlowInput? = nil,
                                 tileGlowBulge: MetalTileGlowBulgeInput? = nil,
                                 slotMask: MetalSlotMaskInput? = nil) throws {
        guard let limit, !clips.isEmpty, color.w > 0 else { return }
        let currentMask = maskDeferred ? nil : maskScope?.input
        let parentMask = maskDeferred ? nil : parentMaskScope?.input
        guard currentMask == nil || inheritedMask == nil else {
            throw PAGError.unsupportedFeature("nestedMaskPaths")
        }
        let mask = inheritedMask ?? currentMask
        guard parentMask == nil || (mask != nil && inheritedMask == nil &&
            texture != nil && video == nil && gradient == nil &&
            featherMaskTexture == nil && trackMatteMode == nil && !isShadow && motionTile == nil &&
            bulge == nil && cornerPin == nil && textBulgeMap == nil && tileGlowBulge == nil) else {
            throw PAGError.unsupportedFeature("nestedMaskPaths")
        }
        guard mask == nil || featherMaskTexture == nil || trackMatteMode != nil,
              trackMatteMode == nil || featherMaskTexture != nil else {
            throw PAGError.unsupportedFeature("nestedMaskPaths")
        }
        let transform = try MetalDrawTransform(matrix: matrix, origin: mesh.source.origin)
        let rawBounds = try transform.bounds(mesh.bounds)
        guard var bounds = rawBounds.intersection(limit) else { return }
        if let clipBounds = clips.bounds {
            guard let visible = bounds.intersection(clipBounds) else { return }
            bounds = visible
        }
        if let deferredClips {
            // 祖先alpha组已经移走coverage；这里仍先排除真实不可见图元，避免先准备无效渐变。
            try budget.reserve(256 + (deferredClips.count + clips.count) * 128)
            let visibility = try deferredClips.merging(clips)
            guard try !visibility.polygon(in: bounds).vertices.isEmpty else { return }
        }
        try budget.reserve(384 + clips.count * 128 + (gradient == nil ? 0 : 256) + (mask == nil ? 0 : 128))
        draws.append(MetalPendingDraw(mesh: mesh, texture: texture, slotMask: slotMask, featherMaskTexture: featherMaskTexture,
                                      video: video, gradient: gradient, matrix: matrix, transform: transform,
                                      color: color, clips: clips, mask: mask, bounds: bounds,
                                      trackMatteMode: trackMatteMode, isShadow: isShadow,
                                      motionTile: motionTile, bulge: bulge, cornerPin: cornerPin,
                                      textBulgeMap: textBulgeMap,
                                      parentMask: parentMask, screenBlend: screenBlend,
                                      hardLightBlend: hardLightBlend,
                                      levelsGreenOnly: levelsGreenOnly, motionBlur: motionBlur,
                                      glow: glow, tileGlowBulge: tileGlowBulge))
    }

}
