/// TGFX Gaussian半核的逐像素Metal消费；边缘模式和输出平移均由同一常量控制。
enum MetalFastBlurShaderSource {
    /// 源外Clamp重复边缘或Decal取零；一次只运行一轴，不在片元内假装完成两轴。
    static let source = """
    /// 与Swift侧两个16字节向量同布局的单轴卷积参数。
    struct PAGFastBlurUniforms {
        /// 输入宽高、半径和水平/垂直轴索引。
        uint4 sourceAndKernel;
        /// 输出到输入的像素平移，第三分量为Clamp模式。
        int4 shiftAndMode;
    };
    /// 用上游归一化半核逐像素卷积，源外值由效果边缘模式决定。
    fragment float4 pagFastBlur(PAGFeatherCopyRaster in [[stage_in]],
                                texture2d<float> source [[texture(0)]],
                                constant float *weights [[buffer(1)]],
                                constant PAGFastBlurUniforms &blur [[buffer(2)]]) {
        int2 base = int2(floor(in.position.xy)) - blur.shiftAndMode.xy;
        int2 step = blur.sourceAndKernel.w == 0 ? int2(1, 0) : int2(0, 1);
        int2 maximum = int2(blur.sourceAndKernel.xy) - 1;
        int radius = int(blur.sourceAndKernel.z);
        float4 sum = float4(0);
        for (int offset = -radius; offset <= radius; ++offset) {
            int2 samplePoint = base + step * offset;
            if (blur.shiftAndMode.z != 0) {
                sum += source.read(uint2(clamp(samplePoint, int2(0), maximum))) * weights[abs(offset)];
            } else if (all(samplePoint >= int2(0)) && all(samplePoint <= maximum)) {
                sum += source.read(uint2(samplePoint)) * weights[abs(offset)];
            }
        }
        return sum;
    }
    /// 与Swift侧三个16字节向量同布局的重采样参数。
    struct PAGFastBlurResampleUniforms {
        /// 目标像素中心到源像素坐标的尺度和平移。
        float4 transform;
        /// 当前输入纹理的真实尺寸。
        float4 sourceSize;
        /// 第一分量为Clamp开关。
        int4 edgeMode;
    };
    /// 缩采和最终裁回共用像素中心映射；只有源采样使用原效果的边缘模式。
    fragment float4 pagFastBlurResample(PAGFeatherCopyRaster in [[stage_in]],
                                        texture2d<float> source [[texture(0)]],
                                        constant PAGFastBlurResampleUniforms &uniforms [[buffer(1)]]) {
        float2 sourcePixel = in.position.xy * uniforms.transform.xy + uniforms.transform.zw;
        float2 uv = sourcePixel / uniforms.sourceSize.xy;
        constexpr sampler clampSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        constexpr sampler decalSampler(coord::normalized, address::clamp_to_zero, filter::linear);
        return uniforms.edgeMode.x != 0 ? source.sample(clampSampler, uv) : source.sample(decalSampler, uv);
    }
    """
}
