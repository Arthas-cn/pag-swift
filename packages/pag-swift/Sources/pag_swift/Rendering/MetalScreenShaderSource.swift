/// 与基础MSL拼接编译的整层Screen专用片元，不单独创建GPU程序或第二份渲染核心。
enum MetalScreenShaderSource {
    /// 只在整层局部内容完成后调用；固定混合系数由MetalPipelines设置。
    static let source = """
    /// 真实tag57静态参数使红蓝输出为零，绿色与alpha保留。
    fragment float4 pagScreenGreenImage(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                             const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                             const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                             texture2d<float> image [[texture(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 uv = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 source = image.sample(inputSampler, uv);
        return float4(0.0f, source.g, 0.0f, source.a) * uniforms.color * area;
    }
    /// 完整合成域先作空间平铺，再映到紧致附件并消费绿通道；附件外为透明。
    fragment float4 pagScreenGreenMotionTileImage(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                       const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                       const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                       constant PAGMotionTileUniforms &tile [[buffer(6)]],
                                       constant PAGTextBulgeMap &map [[buffer(11)]],
                                       texture2d<float> image [[texture(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 outputUV = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        float2 inputUV = pagMotionTileCoordinate(outputUV, tile);
        float2 localUV = float2(dot(map.horizontal.xyz, float3(inputUV, 1.0f)),
                                dot(map.vertical.xyz, float3(inputUV, 1.0f)));
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_zero, filter::linear);
        float4 source = image.sample(inputSampler, localUV);
        return float4(0.0f, source.g, 0.0f, source.a) * uniforms.color * area;
    }
    """
}
