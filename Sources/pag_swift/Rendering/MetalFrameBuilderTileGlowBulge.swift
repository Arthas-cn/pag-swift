import Metal

/// 层115已证实的效果顺序：原预合成内容→MotionTile→Glow两轴→Bulge→根目标。
extension MetalFrameBuilder {
    /// 在内容pass之后建立必要的局部附件，并返回单次最终绘制的材质与完整输出矩阵。
    mutating func attachTileGlowBulge(tile: FrameMotionTile, glow: SampledGlow,
                                      bulge: SampledBulge?, clip: FrameClip,
                                      content: MetalGroupAttachment, contentRect: RenderPixelRect,
                                      contentPassIndex: Int) throws -> (texture: any MTLTexture,
                                          input: MetalTileGlowBulgeInput, matrix: SceneAffine)? {
        guard let visible = limit else { return nil }
        // 当前有界采样合同只证明轴对齐等比显示；旋转或负尺度必须另证逆映工作范围。
        guard clip.matrix.b == 0, clip.matrix.c == 0,
              clip.matrix.a > 0, clip.matrix.d == clip.matrix.a else {
            throw PAGError.unsupportedFeature("tileGlowBulgeTransform")
        }
        guard let layout = try TileGlowBulgeLayout(clip: clip, tile: tile,
            glow: glow, bulge: bulge, visible: visible) else { return nil }
        let grid = try MappedGlowGrid(layout: layout, glow: glow)
        let bulgeUniforms: MetalBulgeUniforms?
        if let bulge {
            let scaleX = tile.outputWidth / 100, scaleY = tile.outputHeight / 100
            let logicalWidth = clip.size.width * scaleX
            let logicalHeight = clip.size.height * scaleY
            let origin = try SceneAffine.translation(x: (clip.size.width - logicalWidth) / 2,
                y: (clip.size.height - logicalHeight) / 2)
            let value = try FrameBulge(bulge, placement: origin,
                pixelSize: PAGSize(width: logicalWidth, height: logicalHeight))
            bulgeUniforms = try MetalBulgeUniforms(value)
        } else {
            // 源visibleAt在零height帧跳过Bulge，融合片元必须保持输入坐标不变。
            bulgeUniforms = nil
        }
        let uniforms = try MetalTileGlowBulgeUniforms(layout: layout, grid: grid,
            bulge: bulgeUniforms)
        let tiled = try resources.groups.acquire(width: layout.sample.width,
            height: layout.sample.height, budget: &budget)
        loans.append(tiled)
        let horizontal = try resources.groups.acquire(width: grid.horizontal.width,
            height: grid.horizontal.height, budget: &budget)
        loans.append(horizontal)
        let vertical = try resources.groups.acquire(width: grid.vertical.width,
            height: grid.vertical.height, budget: &budget)
        loans.append(vertical)
        mappedTileGlowWorks[contentPassIndex] = MetalMappedTileGlowWork(content: content,
            tiled: tiled, horizontal: horizontal, vertical: vertical,
            layout: layout, grid: grid, clip: clip, contentRect: contentRect, tile: tile)
        let bounds = layout.tileBounds
        let matrix = try SceneAffine.scale(x: bounds.right - bounds.left,
            y: bounds.bottom - bounds.top)
            .following(.translation(x: bounds.left, y: bounds.top))
        return (tiled.texture, MetalTileGlowBulgeInput(blurred: vertical.texture,
            uniforms: uniforms), matrix)
    }
}
