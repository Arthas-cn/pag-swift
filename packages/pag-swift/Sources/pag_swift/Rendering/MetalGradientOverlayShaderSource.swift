/// 整层GradientOverlay的Angle白黑真实子范围；颜色和源alpha只在局部pass组合一次。
enum MetalGradientOverlayShaderSource {
    /// 与TGFX逆样式矩阵、ConicGradientLayout和Normal样式混合对应的MSL片元。
    static let source = """
    struct PAGGradientOverlayUniforms { float4 sizeAndRotation; };
    fragment float4 pagGradientOverlayAngle(PAGFeatherCopyRaster in [[stage_in]],
                                            texture2d<float> source [[texture(0)]],
                                            constant PAGGradientOverlayUniforms &style [[buffer(1)]]) {
        float2 size = style.sizeAndRotation.xy;
        float2 relative = in.position.xy - size * 0.5f;
        float cosine = style.sizeAndRotation.z, sine = style.sizeAndRotation.w;
        // GradientPaint先旋转样式矩阵；TGFX布局在逆矩阵坐标中用(-y,-x)求圆锥角。
        float2 point = float2(cosine * relative.x + sine * relative.y,
                              -sine * relative.x + cosine * relative.y);
        float t = clamp(atan2(-point.y, -point.x) * 0.15915494309180001f + 0.5f, 0.0f, 1.0f);
        float4 original = source.read(uint2(in.position.xy));
        float4 overlay = float4(float3(1.0f - t) * original.a, original.a);
        // 上游先用DstIn把渐变裁到源alpha，再以Normal把它叠在原图之上。
        return overlay + original * (1.0f - overlay.a);
    }
    """
}
