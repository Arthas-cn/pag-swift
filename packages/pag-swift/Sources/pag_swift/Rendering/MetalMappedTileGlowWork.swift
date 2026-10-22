import Metal

/// 预合成内容pass之后的MotionTile与Glow三段局部工作，根pass仍直接绘制drawable。
struct MetalMappedTileGlowWork {
    /// 已由前一个颜色pass组合的紧致预合成内容。
    let content: MetalGroupAttachment
    /// MotionTile只保存最终可见像素可能反采样的局部邻域。
    let tiled: MetalGroupAttachment
    /// Glow横轴需要保留纵轴五点核的额外缩小网格行。
    let horizontal: MetalGroupAttachment
    /// Glow纵轴供最终Bulge与Merge片元读取。
    let vertical: MetalGroupAttachment
    /// 完整语义输出与局部附件的几何合同。
    let layout: TileGlowBulgeLayout
    /// Glow完整缩小网格和局部两轴矩形。
    let grid: MappedGlowGrid
    /// 原预合成完整大小及显示矩阵。
    let clip: FrameClip
    /// 紧致内容纹理的真实显示位置。
    let contentRect: RenderPixelRect
    /// 上游MotionTile当前帧字段。
    let tile: FrameMotionTile

    /// 必须紧接内容pass编码三段效果，之后的祖先/根pass才可读取结果。
    func encode(commandBuffer: any MTLCommandBuffer, pipelines: MetalPipelines) throws {
        try MetalMappedMotionTilePass(source: content.texture, destination: tiled.texture,
            contentRect: contentRect, layout: layout, clip: clip, tile: tile)
            .encode(commandBuffer: commandBuffer, pipeline: pipelines.mappedMotionTile)
        try MetalMappedGlowBlurPass(source: tiled.texture, destination: horizontal.texture,
            layout: layout, grid: grid, horizontal: true)
            .encode(commandBuffer: commandBuffer, pipeline: pipelines.mappedGlowBlur)
        try MetalMappedGlowBlurPass(source: horizontal.texture, destination: vertical.texture,
            layout: layout, grid: grid, horizontal: false)
            .encode(commandBuffer: commandBuffer, pipeline: pipelines.mappedGlowBlur)
    }
}
