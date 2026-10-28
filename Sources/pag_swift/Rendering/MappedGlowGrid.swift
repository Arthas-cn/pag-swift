import Foundation

/// Glow缩小后的完整像素网格与实际借用的两轴局部矩形；不改变上游取整和采样步长。
struct MappedGlowGrid: Sendable {
    /// 完整MotionTile输入与Glow目标的上游尺寸合同。
    let sampling: GlowSampling
    /// Glow纵轴写入的局部区域，坐标属于完整缩小网格。
    let vertical: RenderPixelRect
    /// 横轴须额外保留纵轴五点核的采样邻域。
    let horizontal: RenderPixelRect

    /// 从可能被Bulge读取的显示范围映入完整Glow网格，只裁剪附件不重排像素中心。
    init(layout: TileGlowBulgeLayout, glow: SampledGlow) throws {
        let bounds = layout.rasterBounds.bounds
        let fullWidth = Double(layout.rasterBounds.width)
        let fullHeight = Double(layout.rasterBounds.height)
        sampling = try GlowSampling(glow, inputWidth: layout.rasterBounds.width,
            inputHeight: layout.rasterBounds.height)
        let x0 = (Double(layout.glowOutput.x) - bounds.left) * Double(sampling.blurWidth) / fullWidth
        let y0 = (Double(layout.glowOutput.y) - bounds.top) * Double(sampling.blurHeight) / fullHeight
        let x1 = (Double(layout.glowOutput.x + layout.glowOutput.width) - bounds.left)
            * Double(sampling.blurWidth) / fullWidth
        let y1 = (Double(layout.glowOutput.y + layout.glowOutput.height) - bounds.top)
            * Double(sampling.blurHeight) / fullHeight
        guard [x0, y0, x1, y1].allSatisfy(\.isFinite),
              let left = Int(exactly: floor(x0 - 1)), let top = Int(exactly: floor(y0 - 1)),
              let right = Int(exactly: ceil(x1 + 1)), let bottom = Int(exactly: ceil(y1 + 1)) else {
            throw PAGError.unsupportedFeature("mappedGlowGrid")
        }
        let bw = Int(sampling.blurWidth), bh = Int(sampling.blurHeight)
        let vx = max(0, left), vy = max(0, top)
        let vr = min(bw, right), vb = min(bh, bottom)
        guard vr > vx, vb > vy else { throw PAGError.renderingFailure("mappedGlowGrid") }
        vertical = RenderPixelRect(x: vx, y: vy, width: vr - vx, height: vb - vy)
        // 纵轴最远采样3.029312个缩小网格像素，再留一个像素供双线性取邻点。
        let hy = max(0, vy - 5), hb = min(bh, vb + 5)
        horizontal = RenderPixelRect(x: vx, y: hy, width: vr - vx, height: hb - hy)
        // 局部Clamp只能在完整语义网格的真实边界生效；内部裁边必须保留双线性左右邻点。
        let cropLeft = Double(layout.sample.x) - bounds.left
        let cropTop = Double(layout.sample.y) - bounds.top
        let cropRight = cropLeft + Double(layout.sample.width)
        let cropBottom = cropTop + Double(layout.sample.height)
        let firstX = max(0, (Double(vx) + 0.5 - 3.029312) * fullWidth / Double(bw))
        let lastX = min(fullWidth, (Double(vr) - 0.5 + 3.029312) * fullWidth / Double(bw))
        let firstY = max(0, (Double(hy) + 0.5) * fullHeight / Double(bh))
        let lastY = min(fullHeight, (Double(hb) - 0.5) * fullHeight / Double(bh))
        guard (cropLeft <= 0 || firstX >= cropLeft + 0.5 - 0.001),
              (cropRight >= fullWidth || lastX <= cropRight - 0.5 + 0.001),
              (cropTop <= 0 || firstY >= cropTop + 0.5 - 0.001),
              (cropBottom >= fullHeight || lastY <= cropBottom - 0.5 + 0.001),
              (hy == 0 || Double(vy) + 0.5 - 3.029312 >= Double(hy) + 0.5 - 0.001),
              (hb == bh || Double(vb) - 0.5 + 3.029312 <= Double(hb) - 0.5 + 0.001) else {
            throw PAGError.unsupportedFeature("mappedGlowHalo")
        }
    }
}
