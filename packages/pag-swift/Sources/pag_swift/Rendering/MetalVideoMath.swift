/// PAG视频采样与颜色的共享MSL数学，显示片元和独立GPU数值测试使用同一份实现。
enum MetalVideoMath {
    /// 只接收标量或纹理坐标，不负责解码、资源分配或最终显示目标。
    static let source = """
    /// 与Swift MetalVideoUniforms一致的32字节输入。
    struct PAGVideoUniforms {
        /// 可见颜色宽高与完整亮度平面的宽高倒数。
        float4 colorRegion;
        /// alpha像素偏移、是否启用alpha、是否翻转纵向纹理原点。
        float4 alphaRegion;
    };
    /// 从可见区域UV得到颜色/alpha的完整平面UV；先钳制像素中心，再加PAG偏移和原点变换。
    inline float4 pagVideoCoordinates(float2 uv, PAGVideoUniforms video) {
        float2 pixel = clamp(uv * video.colorRegion.xy, float2(0.5f), video.colorRegion.xy - 0.5f);
        float4 coordinates = float4(pixel * video.colorRegion.zw,
                                    (pixel + video.alphaRegion.xy) * video.colorRegion.zw);
        if (video.alphaRegion.w != 0) { coordinates.yw = 1.0f - coordinates.yw; }
        return coordinates;
    }
    /// 按GLSLTextureEffect的601有限范围矩阵先钳制RGB，再以PAG的218分母alpha预乘。
    inline float4 pagVideoColor(float3 yuv, float alphaY, bool hasAlpha) {
        yuv -= float3(16.0f / 255.0f, 0.5f, 0.5f);
        float3 rgb = clamp(float3(1.164384f * yuv.x + 1.596027f * yuv.z,
                                  1.164384f * yuv.x - 0.391762f * yuv.y - 0.812968f * yuv.z,
                                  1.164384f * yuv.x + 2.017232f * yuv.y), 0.0f, 1.0f);
        // 非零偏移才启用alpha；文件hasAlpha只说明字段是否存在，不能替代该判断。
        float alpha = hasAlpha ? clamp((alphaY - 16.0f / 255.0f) / (218.0f / 255.0f), 0.0f, 1.0f) : 1.0f;
        return float4(rgb * alpha, alpha);
    }
    """
}
