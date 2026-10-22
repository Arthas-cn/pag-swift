import Metal

/// 根颜色pass把局部MotionTile与Glow结果按完整语义域取样，再执行Bulge和Glow合并。
struct MetalTileGlowBulgeUniforms {
    /// 完整平铺输出在最终显示像素域的左上角及宽高。
    let tileRect: SIMD4<Float>
    /// 局部MotionTile纹理在显示像素域的左上角及宽高。
    let tileSample: SIMD4<Float>
    /// Glow完整输入像素网格的整数边界；与连续MotionTile矩形允许不同原点。
    let glowRasterRect: SIMD4<Float>
    /// Glow第二轴局部纹理在完整缩小网格的位置及宽高。
    let glowSample: SIMD4<Float>
    /// 完整Glow缩小网格宽高、RGB阈值和Bulge启用位。
    let glowSizeAndOptions: SIMD4<Float>
    /// Bulge中心、半径、输出矩形与高度；未启用时仅保留有效占位值。
    let bulge: MetalBulgeUniforms

    /// 建立两份局部纹理到完整效果域的映射，拒绝无法表示的GPU坐标。
    init(layout: TileGlowBulgeLayout, grid: MappedGlowGrid, bulge: MetalBulgeUniforms?) throws {
        let bounds = layout.tileBounds
        tileRect = SIMD4(Float(bounds.left), Float(bounds.top),
            Float(bounds.right - bounds.left), Float(bounds.bottom - bounds.top))
        tileSample = SIMD4(Float(layout.sample.x), Float(layout.sample.y),
            Float(layout.sample.width), Float(layout.sample.height))
        glowRasterRect = SIMD4(Float(layout.rasterBounds.x), Float(layout.rasterBounds.y),
            Float(layout.rasterBounds.width), Float(layout.rasterBounds.height))
        glowSample = SIMD4(Float(grid.vertical.x), Float(grid.vertical.y),
            Float(grid.vertical.width), Float(grid.vertical.height))
        glowSizeAndOptions = SIMD4(Float(grid.sampling.blurWidth),
            Float(grid.sampling.blurHeight), grid.sampling.threshold, bulge == nil ? 0 : 1)
        self.bulge = bulge ?? MetalBulgeUniforms.placeholder
        guard (0..<4).allSatisfy({ tileRect[$0].isFinite && tileSample[$0].isFinite &&
              glowRasterRect[$0].isFinite && glowSample[$0].isFinite &&
              glowSizeAndOptions[$0].isFinite }),
              tileRect.z > 0, tileRect.w > 0, glowRasterRect.z > 0,
              glowRasterRect.w > 0, glowSizeAndOptions.z > 0 else {
            throw PAGError.unsupportedFeature("tileGlowBulgeCoordinates")
        }
    }
}

extension MetalBulgeUniforms {
    /// Bulge缺席的帧只走原单位坐标；占位常量不会进入着色器的Bulge分支。
    fileprivate static let placeholder = MetalBulgeUniforms(
        centerAndRadii: SIMD4(0.5, 0.5, 1, 1),
        outputRect: SIMD4(0, 0, 1, 1),
        heightAndPinning: SIMD4(0, 1, 0, 0))
}

/// 一个真实图层结果draw的附加输入；Glow结果在同一最终pass读取而不生成整帧副本。
struct MetalTileGlowBulgeInput {
    /// Glow纵轴完成后保活至GPU提交结束的局部BGRA8纹理。
    let blurred: any MTLTexture
    /// 完整效果域与两份局部附件的只读采样参数。
    let uniforms: MetalTileGlowBulgeUniforms
}
