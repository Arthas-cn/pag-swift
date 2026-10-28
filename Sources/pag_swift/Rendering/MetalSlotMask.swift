import Metal

/// 同一图像 draw 的额外 alpha 纹理，不新建离屏 pass，也不改变原 PAG mask 栈。
struct MetalSlotMaskInput {
    /// 通过既有图像缓存上传的静态遮罩，随当前 GPU 批次保活。
    let texture: any MTLTexture
    /// 最终显示像素到遮罩 UV 的映射，局部组 pass 同样使用全局坐标查询。
    let uniforms: MetalSlotMaskUniforms
}

/// 与 MSL 一致的两行常量；关闭时 horizontal.w 为零，其它系数不被读取。
struct MetalSlotMaskUniforms {
    /// UV.x 的 a/c/tx，w 为 0 或 1 的启用标志。
    var horizontal = SIMD4<Float>.zero
    /// UV.y 的 b/d/ty，w 保留为零。
    var vertical = SIMD4<Float>.zero

    /// 无额外遮罩时仍绑定固定常量，保证共用图像管线的行为确定。
    init() {}

    /// 从已求值矩阵准备有限 Float 常量，溢出时拒绝当前绘制而非采样错误像素。
    init(_ mask: FrameImageMask) throws {
        let inverse = try mask.matrix.inverted().following(.scale(x: 1 / mask.pixelSize.width,
                                                                 y: 1 / mask.pixelSize.height))
        horizontal = SIMD4(Float(inverse.a), Float(inverse.c), Float(inverse.tx), 1)
        vertical = SIMD4(Float(inverse.b), Float(inverse.d), Float(inverse.ty), 0)
        guard (0..<4).allSatisfy({ horizontal[$0].isFinite && vertical[$0].isFinite }) else {
            throw PAGError.renderingFailure("slotMaskTransform")
        }
    }
}

/// 只采样 alpha 的共享内核；图层路径与形状覆盖仍由既有片元入口分别求值。
enum MetalSlotMaskShader {
    /// 不依赖 PAGUniforms，放在公共 shader 定义之前以供普通/单路径/双路径图像入口复用。
    static let source = """
    struct PAGSlotMaskUniforms { float4 horizontal; float4 vertical; };
    inline float pagSlotMaskAlpha(float2 pixel, constant PAGSlotMaskUniforms &mask,
                                  texture2d<float> alphaImage) {
        if (mask.horizontal.w == 0) { return 1.0f; }
        float3 point = float3(pixel, 1.0f);
        float2 uv = float2(dot(mask.horizontal.xyz, point), dot(mask.vertical.xyz, point));
        if (any(uv < 0.0f) || any(uv > 1.0f)) { return 0.0f; }
        constexpr sampler alphaSampler(coord::normalized, address::clamp_to_zero, filter::linear);
        return alphaImage.sample(alphaSampler, uv).a;
    }
    """
}
