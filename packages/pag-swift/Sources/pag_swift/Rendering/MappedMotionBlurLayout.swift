import Foundation

/// 无前置Effects的预合成MotionBlur输入域、紧致内容附件与扩大后的最终几何。
struct MappedMotionBlurLayout {
    /// 上游measureBounds后roundOut的图层局部内容域，用于速度矩阵归一化。
    let semantic: RenderBounds
    /// 内容pass使用的真实显示像素区域，不附加会改变Clamp边缘的一像素halo。
    let contentRect: RenderPixelRect
    /// 滤镜输出1.2倍局部矩形到最终显示像素的矩阵。
    let outputMatrix: SceneAffine
    /// 完整语义UV映到紧致内容附件UV的两行。
    let map: MetalTextBulgeMap
    /// 上游37样本矩阵和采样中心。
    let blur: MetalMotionBlurUniforms

    /// 以层变换逆映真实子内容，再按上游局部roundOut建立输入和输出合同。
    init?(displayBounds: RenderBounds, sourceLimit: RenderBounds,
          clip: FrameClip, sampling: MotionBlurSampling) throws {
        // 仅证明了轴向正尺度下AABB逆映；旋转/负尺度另需多边形边界审计。
        guard clip.matrix.b == 0, clip.matrix.c == 0,
              clip.matrix.a > 0, clip.matrix.d > 0 else {
            throw PAGError.unsupportedFeature("mappedMotionBlurTransform")
        }
        let local = try displayBounds.transformed(by: clip.matrix.inverted())
        let rounded = try RenderBounds(left: floor(local.left), top: floor(local.top),
            right: ceil(local.right), bottom: ceil(local.bottom))
        let display = try rounded.transformed(by: clip.matrix)
        guard let rect = try display.exactPixelRect(clippedTo: sourceLimit) else { return nil }
        let output = try sampling.outputBounds(for: rounded)
        let matrix = try SceneAffine.scale(x: output.right - output.left,
            y: output.bottom - output.top)
            .following(.translation(x: output.left, y: output.top))
            .following(clip.matrix)
        semantic = rounded
        contentRect = rect
        outputMatrix = matrix
        map = try MetalTextBulgeMap(effectBounds: rounded, effectMatrix: clip.matrix, rect: rect)
        blur = try MetalMotionBlurUniforms(sampling, inputBounds: rounded)
    }
}
