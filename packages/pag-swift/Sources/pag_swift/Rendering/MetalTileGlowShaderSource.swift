/// 预合成MotionTile的局部输出着色器；输入和输出附件可紧致，效果坐标仍属于完整合成域。
enum MetalTileGlowShaderSource {
    /// 每个局部像素先映回完整平铺输出，再按上游公式求原预合成坐标。
    static let source = """
    struct PAGMappedTileUniforms {
        float4 outputRect;
        float4 localOrigin;
        float4 sourceX;
        float4 sourceY;
    };
    fragment float4 pagMappedMotionTile(PAGFeatherCopyRaster in [[stage_in]],
                                        texture2d<float> source [[texture(0)]],
                                        constant PAGMappedTileUniforms &map [[buffer(1)]],
                                        constant PAGMotionTileUniforms &tile [[buffer(2)]]) {
        float2 display = in.position.xy + map.localOrigin.xy;
        float2 outputUV = (display - map.outputRect.xy) / map.outputRect.zw;
        float2 q = pagMotionTileCoordinate(outputUV, tile);
        float3 homogeneous = float3(q, 1.0f);
        float2 sourceUV = float2(dot(map.sourceX.xyz, homogeneous),
                                  dot(map.sourceY.xyz, homogeneous));
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_zero, filter::linear);
        return source.sample(inputSampler, sourceUV);
    }
    struct PAGMappedGlowUniforms {
        float4 destinationAndSize;
        float4 sourceRect;
        float4 sourceSize;
        float4 step;
    };
    inline float4 pagMappedGlowSample(float2 fullUV, texture2d<float> source,
                                      constant PAGMappedGlowUniforms &map) {
        float2 sourceUV = (clamp(fullUV, float2(0), float2(1)) * map.sourceSize.xy
                          - map.sourceRect.xy) / map.sourceRect.zw;
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        return source.sample(inputSampler, sourceUV);
    }
    fragment float4 pagMappedGlowBlur(PAGFeatherCopyRaster in [[stage_in]],
                                      texture2d<float> source [[texture(0)]],
                                      constant PAGMappedGlowUniforms &map [[buffer(1)]]) {
        float2 uv = (in.position.xy + map.destinationAndSize.xy) / map.destinationAndSize.zw;
        float4 sum = pagMappedGlowSample(uv, source, map) * 0.398943f;
        sum += pagMappedGlowSample(uv + map.step.xy * 1.182425f, source, map) * 0.295963f;
        sum += pagMappedGlowSample(uv - map.step.xy * 1.182425f, source, map) * 0.295963f;
        sum += pagMappedGlowSample(uv + map.step.xy * 3.029312f, source, map) * 0.004566f;
        sum += pagMappedGlowSample(uv - map.step.xy * 3.029312f, source, map) * 0.004566f;
        return sum;
    }
    struct PAGTileGlowBulgeUniforms {
        float4 tileRect;
        float4 tileSample;
        float4 glowRasterRect;
        float4 glowSample;
        float4 glowSizeAndOptions;
        PAGBulgeUniforms bulge;
    };
    fragment float4 pagTileGlowBulgeImage(PAGRaster in [[stage_in]],
                                          constant PAGUniforms &uniforms [[buffer(1)]],
                                          const device float4 *clips [[buffer(2)]],
                                          const device PAGCoverageNode *nodes [[buffer(3)]],
                                          const device uint *triangles [[buffer(4)]],
                                          const device PAGCoverageVertex *vertices [[buffer(5)]],
                                          constant PAGTileGlowBulgeUniforms &map [[buffer(11)]],
                                          texture2d<float> tiled [[texture(0)]],
                                          texture2d<float> blurred [[texture(1)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float coverage = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 outputUV = (pixel - map.tileRect.xy) / map.tileRect.zw;
        float2 q = map.glowSizeAndOptions.w != 0.0f ?
            pagBulgeCoordinate(outputUV, map.bulge) : outputUV;
        float2 tileUV = (q * map.tileRect.zw + map.tileRect.xy - map.tileSample.xy)
                        / map.tileSample.zw;
        float2 glowPixel = q * map.tileRect.zw + map.tileRect.xy;
        float2 glowFullUV = (glowPixel - map.glowRasterRect.xy) / map.glowRasterRect.zw;
        float2 glowUV = (glowFullUV * map.glowSizeAndOptions.xy - map.glowSample.xy)
                        / map.glowSample.zw;
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_zero, filter::linear);
        float4 original = tiled.sample(inputSampler, tileUV);
        float4 glow = blurred.sample(inputSampler, glowUV);
        float3 rgb = clamp(max(original.rgb, glow.rgb) / map.glowSizeAndOptions.z, 0.0f, 1.0f);
        return float4(rgb, original.a) * uniforms.color * coverage;
    }
    """
}
