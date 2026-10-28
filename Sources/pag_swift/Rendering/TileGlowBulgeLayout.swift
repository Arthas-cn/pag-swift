import Foundation

/// 层115三段效果在显示像素域的保守工作范围；只算几何，不借GPU附件。
struct TileGlowBulgeLayout: Sendable {
    /// MotionTile按完整预合成输入域扩出的语义输出范围，不能用局部附件尺寸替代。
    let tileBounds: RenderBounds
    /// 连续输出四边向外取整后的完整Glow输入网格；分数显示原点不能截断像素中心。
    let rasterBounds: RenderPixelRect
    /// 根目标实际可能显示该层的整数范围。
    let output: RenderPixelRect
    /// Bulge逆映后可能落入的Glow合并结果范围，不含Glow卷积输入halo。
    let glowOutput: RenderPixelRect
    /// 当前帧Bulge逆采样与Glow五点核可能读取的保守整数范围。
    let sample: RenderPixelRect

    /// 用上游Bulge逆映位移与Glow最大采样偏移裁出必要区域；零height帧只需Glow邻域。
    init?(clip: FrameClip, tile: FrameMotionTile, glow: SampledGlow,
          bulge: SampledBulge?, visible: RenderBounds) throws {
        guard tile.outputWidth.isFinite, tile.outputHeight.isFinite,
              tile.outputWidth > 0, tile.outputHeight > 0 else {
            throw PAGError.unsupportedFeature("tileGlowBulgeBounds")
        }
        let scale = Double(try FastBlurSampling.displayScale(of: clip.matrix))
        let width = clip.size.width * tile.outputWidth / 100
        let height = clip.size.height * tile.outputHeight / 100
        let left = (clip.size.width - width) / 2
        let top = (clip.size.height - height) / 2
        let logical = try RenderBounds(left: left, top: top,
            right: left + width, bottom: top + height)
        let tileBounds = try logical.transformed(by: clip.matrix)
        guard let intersection = tileBounds.intersection(visible) else { return nil }
        // 上游在效果边界roundOut；Glow的完整输入网格与连续MotionTile矩形须分别保留。
        guard let rasterBounds = try tileBounds.exactPixelRect(clippedTo: tileBounds) else { return nil }
        let displacement: Double
        if let bulge {
            guard bulge.pinning, bulge.horizontalRadius > 0, bulge.verticalRadius > 0,
                  bulge.height.isFinite else {
                throw PAGError.unsupportedFeature("tileGlowBulgeBounds")
            }
            let radius = max(bulge.horizontalRadius / width, bulge.verticalRadius / height)
            guard radius.isFinite, radius > 0, radius < 1 else {
                throw PAGError.unsupportedFeature("tileGlowBulgeBounds")
            }
            // 上游weight=(1-distance)*atan(len,sqrt(1-sqrt(len)))/π；椭圆内len不超过最大归一半径。
            let angle = atan2(radius, sqrt(1 - sqrt(radius))) / .pi
            displacement = abs(bulge.height) * angle * max(width, height) * scale
        } else {
            // 源visibleAt对零height跳过Bulge，此帧不需要为不存在的逆采样留halo。
            displacement = 0
        }
        let fullWidth = rasterBounds.width, fullHeight = rasterBounds.height
        let glowLayout = try GlowSampling(glow, inputWidth: fullWidth,
                                          inputHeight: fullHeight)
        // 五点核最大偏移3.029312，缩小Glow附件的UV步长须映回原完整输出像素。
        let tapX = 3.029312 * Double(fullWidth) / Double(glowLayout.blurWidth)
        let tapY = 3.029312 * Double(fullHeight) / Double(glowLayout.blurHeight)
        // Glow缩小网格的整数对齐和纵轴额外五点邻域会跨过连续边界，再留6像素覆盖双线性取邻点。
        let halo = ceil(displacement + max(tapX, tapY) + 6)
        guard halo.isFinite, halo >= 0, halo <= 16_384 else {
            throw PAGError.resourceLimitExceeded("tileGlowBulgeBounds")
        }
        let glowNeeded = try RenderBounds(left: intersection.left - displacement - 2,
            top: intersection.top - displacement - 2,
            right: intersection.right + displacement + 2,
            bottom: intersection.bottom + displacement + 2)
        let needed = try RenderBounds(left: intersection.left - halo,
            top: intersection.top - halo, right: intersection.right + halo,
            bottom: intersection.bottom + halo)
        guard let output = try intersection.pixelRect(clippedTo: intersection),
              let glowOutput = try glowNeeded.pixelRect(clippedTo: tileBounds),
              let sample = try needed.pixelRect(clippedTo: tileBounds) else { return nil }
        self.tileBounds = tileBounds
        self.rasterBounds = rasterBounds
        self.output = output
        self.glowOutput = glowOutput
        self.sample = sample
    }
}
