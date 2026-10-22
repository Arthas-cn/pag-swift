/// 五个float4与MSL常量逐字段对齐；速度矩阵对应效果后的完整层域，不是紧附件。
struct MetalMotionBlurUniforms {
    /// 上一帧归一纹理变换的水平行，最后一项填零。
    let previousHorizontal: SIMD4<Float>
    /// 上一帧归一纹理变换的垂直行。
    let previousVertical: SIMD4<Float>
    /// 当前帧归一纹理变换的水平行。
    let currentHorizontal: SIMD4<Float>
    /// 当前帧归一纹理变换的垂直行。
    let currentVertical: SIMD4<Float>
    /// x为上游采样中心，y为最大归一距离0.1；其余留零。
    let parameters: SIMD4<Float>

    /// 按MotionBlurFilter的Float纹理矩阵生成GPU常量；退化或溢出输入会抛错。
    init(_ sampling: MotionBlurSampling, inputBounds: RenderBounds) throws {
        let pair = try sampling.textureTransforms(in: inputBounds)
        previousHorizontal = SIMD4(pair.previous.horizontal, 0)
        previousVertical = SIMD4(pair.previous.vertical, 0)
        currentHorizontal = SIMD4(pair.current.horizontal, 0)
        currentVertical = SIMD4(pair.current.vertical, 0)
        parameters = SIMD4(pair.velocityCenter, 0.1, 0, 0)
    }
}

/// 与基础MSL拼接的37样本MotionBlur片元；预合成或图像效果结果均直接写最终目标。
enum MetalMotionBlurShaderSource {
    /// 按输入材质分别读取紧致内容、图像平铺或Screen绿通道效果结果。
    static let source = """
    struct PAGMotionBlurUniforms {
        float4 previousHorizontal;
        float4 previousVertical;
        float4 currentHorizontal;
        float4 currentVertical;
        float4 parameters;
    };
    /// 无前置Effects的预合成直接从紧致内容附件读取；UV仍属于完整可见内容域。
    inline float4 pagMappedMotionBlurSample(float2 uv, constant PAGTextBulgeMap &map,
                                             texture2d<float> image) {
        float2 localUV = float2(dot(map.horizontal.xyz, float3(uv, 1.0f)),
                                dot(map.vertical.xyz, float3(uv, 1.0f)));
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_zero, filter::linear);
        return image.sample(inputSampler, localUV);
    }
    fragment float4 pagMappedMotionBlurImage(PAGRaster in [[stage_in]],
                                              constant PAGUniforms &uniforms [[buffer(1)]],
                                              const device float4 *clips [[buffer(2)]],
                                              const device PAGCoverageNode *nodes [[buffer(3)]],
                                              const device uint *triangles [[buffer(4)]],
                                              const device PAGCoverageVertex *vertices [[buffer(5)]],
                                              constant PAGTextBulgeMap &map [[buffer(11)]],
                                              constant PAGMotionBlurUniforms &blur [[buffer(16)]],
                                              texture2d<float> image [[texture(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 outputUV = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        float2 uv = outputUV * 1.2f - 0.1f;
        float3 point = float3(uv, 1.0f);
        float2 previous = float2(dot(blur.previousHorizontal.xyz, point),
                                 dot(blur.previousVertical.xyz, point));
        float2 current = float2(dot(blur.currentHorizontal.xyz, point),
                                dot(blur.currentVertical.xyz, point));
        float2 velocity = current - previous;
        float distance = length(velocity);
        velocity *= min(distance, blur.parameters.y) / distance;
        float4 result = pagMappedMotionBlurSample(clamp(uv, 0.0f, 1.0f), map, image);
        float outside = 0.0f;
        for (int i = 1; i < 37; ++i) {
            float2 target = uv + velocity * (float(i) / 36.0f - blur.parameters.x);
            if (all(target >= float2(0.0f)) && all(target < float2(1.0f))) {
                result += pagMappedMotionBlurSample(target, map, image);
            } else {
                outside += 1.0f;
            }
        }
        return (outside < 36.0f ? result / 37.0f : float4(0.0f)) * uniforms.color * area;
    }
    /// 完整图像平铺先于37次模糊采样；同一片元直接写目标，无整帧效果副本。
    fragment float4 pagMotionTileBlurImage(PAGRaster in [[stage_in]],
                                            constant PAGUniforms &uniforms [[buffer(1)]],
                                            const device float4 *clips [[buffer(2)]],
                                            const device PAGCoverageNode *nodes [[buffer(3)]],
                                            const device uint *triangles [[buffer(4)]],
                                            const device PAGCoverageVertex *vertices [[buffer(5)]],
                                            constant PAGMotionTileUniforms &tile [[buffer(6)]],
                                            constant PAGMotionBlurUniforms &blur [[buffer(16)]],
                                            texture2d<float> image [[texture(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 outputUV = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        float2 uv = outputUV * 1.2f - 0.1f;
        float3 point = float3(uv, 1.0f);
        float2 previous = float2(dot(blur.previousHorizontal.xyz, point),
                                 dot(blur.previousVertical.xyz, point));
        float2 current = float2(dot(blur.currentHorizontal.xyz, point),
                                dot(blur.currentVertical.xyz, point));
        float2 velocity = current - previous;
        float distance = length(velocity);
        velocity *= min(distance, blur.parameters.y) / distance;
        float4 result = pagMotionTileSample(clamp(uv, 0.0f, 1.0f), tile, image);
        float outside = 0.0f;
        for (int i = 1; i < 37; ++i) {
            float2 target = uv + velocity * (float(i) / 36.0f - blur.parameters.x);
            if (all(target >= float2(0.0f)) && all(target < float2(1.0f))) {
                result += pagMotionTileSample(target, tile, image);
            } else {
                outside += 1.0f;
            }
        }
        return (outside < 36.0f ? result / 37.0f : float4(0.0f)) * uniforms.color * area;
    }
    /// 紧附件仅存有色区域；坐标仍从完整预合成平铺域映入。
    inline float4 pagMotionBlurTileSample(float2 uv, constant PAGMotionTileUniforms &tile,
                                           constant PAGTextBulgeMap &map, texture2d<float> image) {
        float2 inputUV = pagMotionTileCoordinate(uv, tile);
        float2 localUV = float2(dot(map.horizontal.xyz, float3(inputUV, 1.0f)),
                                dot(map.vertical.xyz, float3(inputUV, 1.0f)));
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_zero, filter::linear);
        return image.sample(inputSampler, localUV);
    }
    /// 采样边界及固定除数照上游：首样本不计边界，后36个越界样本只增加计数。
    fragment float4 pagScreenGreenMotionTileBlurImage(PAGRaster in [[stage_in]],
                                   constant PAGUniforms &uniforms [[buffer(1)]],
                                   const device float4 *clips [[buffer(2)]],
                                   const device PAGCoverageNode *nodes [[buffer(3)]],
                                   const device uint *triangles [[buffer(4)]],
                                   const device PAGCoverageVertex *vertices [[buffer(5)]],
                                   constant PAGMotionTileUniforms &tile [[buffer(6)]],
                                   constant PAGTextBulgeMap &map [[buffer(11)]],
                                   constant PAGMotionBlurUniforms &blur [[buffer(16)]],
                                   texture2d<float> image [[texture(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 outputUV = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        // 输出矩形在效果输入两侧各扩0.1；滤镜纹理坐标必须恢复到扩大前的域。
        float2 uv = outputUV * 1.2f - 0.1f;
        float3 point = float3(uv, 1.0f);
        float2 previous = float2(dot(blur.previousHorizontal.xyz, point),
                                 dot(blur.previousVertical.xyz, point));
        float2 current = float2(dot(blur.currentHorizontal.xyz, point),
                                dot(blur.currentVertical.xyz, point));
        float2 velocity = current - previous;
        float distance = length(velocity);
        velocity *= min(distance, blur.parameters.y) / distance;
        float4 result = pagMotionBlurTileSample(clamp(uv, 0.0f, 1.0f), tile, map, image);
        float outside = 0.0f;
        for (int i = 1; i < 37; ++i) {
            float2 target = uv + velocity * (float(i) / 36.0f - blur.parameters.x);
            if (all(target >= float2(0.0f)) && all(target < float2(1.0f))) {
                result += pagMotionBlurTileSample(target, tile, map, image);
            } else {
                outside += 1.0f;
            }
        }
        float4 source = outside < 36.0f ? result / 37.0f : float4(0.0f);
        return float4(0.0f, source.g, 0.0f, source.a) * uniforms.color * area;
    }
    """
}
