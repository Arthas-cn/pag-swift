/// 与基础MSL拼接的Glow五点分轴采样；结果必须经过两个BGRA8局部附件才能合并原图。
enum MetalGlowShaderSource {
    /// 横轴先在缩小目标上线性ClampToEdge，纵轴再在同尺寸附件上线性ClampToEdge。
    static let source = """
    fragment float4 pagGlowBlur(PAGFeatherCopyRaster in [[stage_in]],
                                texture2d<float> source [[texture(0)]],
                                constant float4 &step [[buffer(1)]]) {
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 sum = source.sample(inputSampler, in.uv) * 0.398943f;
        sum += source.sample(inputSampler, in.uv + step.xy * 1.182425f) * 0.295963f;
        sum += source.sample(inputSampler, in.uv - step.xy * 1.182425f) * 0.295963f;
        sum += source.sample(inputSampler, in.uv + step.xy * 3.029312f) * 0.004566f;
        sum += source.sample(inputSampler, in.uv - step.xy * 3.029312f) * 0.004566f;
        return sum;
    }
    /// 后续FastBlur需读取完整Glow结果，因此在局部BGRA8附件先按同一UV完成Merge。
    fragment float4 pagGlowMergeLocal(PAGFeatherCopyRaster in [[stage_in]],
                                      texture2d<float> source [[texture(0)]],
                                      texture2d<float> blurred [[texture(1)]],
                                      constant float &threshold [[buffer(1)]]) {
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 original = source.sample(inputSampler, in.uv);
        float3 color = clamp(max(original.rgb, blurred.sample(inputSampler, in.uv).rgb) / threshold,
                             0.0f, 1.0f);
        return float4(color, original.a);
    }
    /// 先逐通道保留较亮的预乘RGB，再按上游阈值除法钳制；alpha只取原图。
    fragment float4 pagGlowImage(PAGRaster in [[stage_in]],
                                 constant PAGUniforms &uniforms [[buffer(1)]],
                                 const device float4 *clips [[buffer(2)]],
                                 const device PAGCoverageNode *nodes [[buffer(3)]],
                                 const device uint *triangles [[buffer(4)]],
                                 const device PAGCoverageVertex *vertices [[buffer(5)]],
                                 constant float &threshold [[buffer(11)]],
                                 texture2d<float> source [[texture(0)]],
                                 texture2d<float> blurred [[texture(1)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 uv = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 original = source.sample(inputSampler, uv);
        float3 color = clamp(max(original.rgb, blurred.sample(inputSampler, uv).rgb) / threshold,
                             0.0f, 1.0f);
        return float4(color, original.a) * uniforms.color * area;
    }
    """
}
