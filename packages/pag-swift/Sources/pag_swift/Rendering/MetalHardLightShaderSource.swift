/// 仅Apple GPU可编程混合管线使用的HardLight片元；直接读取当前颜色附件。
enum MetalHardLightShaderSource {
    /// 预乘颜色分段公式来自上游TGFX GLSLBlend::HardLight，alpha仍按SrcOver。
    static let source = """
    inline float4 pagHardLightBlend(float4 source, float4 destination) {
        float3 interaction;
        // 上游按源预乘通道的半alpha分段，不能把HardLight当作固定混合系数。
        interaction.r = 2.0f * source.r < source.a ? 2.0f * source.r * destination.r :
            source.a * destination.a - 2.0f * (destination.a - destination.r) * (source.a - source.r);
        interaction.g = 2.0f * source.g < source.a ? 2.0f * source.g * destination.g :
            source.a * destination.a - 2.0f * (destination.a - destination.g) * (source.a - source.g);
        interaction.b = 2.0f * source.b < source.a ? 2.0f * source.b * destination.b :
            source.a * destination.a - 2.0f * (destination.a - destination.b) * (source.a - source.b);
        float3 rgb = interaction + source.rgb * (1.0f - destination.a) +
            destination.rgb * (1.0f - source.a);
        return float4(rgb, source.a + (1.0f - source.a) * destination.a);
    }
    fragment float4 pagHardLightImage(PAGRaster in [[stage_in]],
                                     constant PAGUniforms &uniforms [[buffer(1)]],
                                     const device float4 *clips [[buffer(2)]],
                                     const device PAGCoverageNode *nodes [[buffer(3)]],
                                     const device uint *triangles [[buffer(4)]],
                                     const device PAGCoverageVertex *vertices [[buffer(5)]],
                                     texture2d<float> image [[texture(0)]],
                                     float4 destination [[color(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 uv = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        constexpr sampler sourceSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 source = image.sample(sourceSampler, uv) * uniforms.color * area;
        return pagHardLightBlend(source, destination);
    }
    fragment float4 pagHardLightTrackMatteImage(PAGRaster in [[stage_in]],
                                                constant PAGUniforms &uniforms [[buffer(1)]],
                                                const device float4 *clips [[buffer(2)]],
                                                const device PAGCoverageNode *nodes [[buffer(3)]],
                                                const device uint *triangles [[buffer(4)]],
                                                const device PAGCoverageVertex *vertices [[buffer(5)]],
                                                constant uint &mode [[buffer(11)]],
                                                texture2d<float> content [[texture(0)]],
                                                texture2d<float> maskImage [[texture(1)]],
                                                float4 destination [[color(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 uv = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 mask = maskImage.sample(inputSampler, uv);
        float factor = mode >= 3 ? dot(mask.rgb, float3(0.2126f, 0.7152f, 0.0722f)) : mask.a;
        if (mode == 2 || mode == 4) { factor = 1.0f - factor; }
        // Track Matte与整体alpha均先作用于完整滤镜结果，然后才读取此前背景作HardLight。
        float4 source = content.sample(inputSampler, uv) * (factor * uniforms.color * area);
        return pagHardLightBlend(source, destination);
    }
    """
}
