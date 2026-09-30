import Metal

/// 只在后台owner创建并保活的基础绘制管线；不暴露系统对象或创建最终画面纹理。
struct MetalPipelines {
    /// 预乘纯色填充，支持真实矩形裁剪。
    let solid: any MTLRenderPipelineState
    /// 预乘RGBA输入采样，与纯色使用相同SrcOver混合。
    let image: any MTLRenderPipelineState
    /// 直接从硬解NV12采样并预乘PAG alpha，最终仍使用同一SrcOver显示附件。
    let video: any MTLRenderPipelineState
    /// 有界解析渐变共享覆盖和SrcOver，直接写当前显示附件。
    let gradient: any MTLRenderPipelineState

    /// 首次使用时编译共享MSL并创建管线；任何编译/创建错误转换为可跨actor的领域错误。
    init(device: any MTLDevice) throws {
        try Task.checkCancellation()
        do {
            let library = try device.makeLibrary(source: MetalShaderSource.source, options: nil)
            solid = try Self.make(device: device, library: library, fragment: "pagSolid")
            image = try Self.make(device: device, library: library, fragment: "pagImage")
            video = try Self.make(device: device, library: library, fragment: "pagVideo")
            gradient = try Self.make(device: device, library: library, fragment: "pagGradient")
        } catch is CancellationError { throw CancellationError() }
        catch { throw PAGError.renderingFailure("metalPipeline: \(error.localizedDescription)") }
        try Task.checkCancellation()
    }

    /// 所有基础内容直接匹配BGRA8单采样drawable，输入已经预乘，不能再次使用sourceAlpha因子。
    private static func make(device: any MTLDevice, library: any MTLLibrary,
                             fragment: String) throws -> any MTLRenderPipelineState {
        guard let vertex = library.makeFunction(name: "pagVertex"), let pixel = library.makeFunction(name: fragment) else {
            throw PAGError.renderingFailure("metalFunctionMissing")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "pag.\(fragment)"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = pixel
        descriptor.rasterSampleCount = 1
        guard let color = descriptor.colorAttachments[0] else { throw PAGError.renderingFailure("metalColorAttachment") }
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.rgbBlendOperation = .add
        color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}

/// 随库编译的MSL源码，首次GPU使用才在后台编译；不在播放循环中创建library。
private enum MetalShaderSource {
    /// 数学内核与计算验证共用，显示入口只负责目标映射、资源绑定与颜色采样。
    static let source = "#include <metal_stdlib>\nusing namespace metal;\n" + MetalCoverageMath.source + MetalVideoMath.source + MetalGradientMath.source + """
    /// 共享常量布局必须和Swift端的112字节结构一致。
    struct PAGUniforms {
        /// 网格局部到最终显示像素x的行向量。
        float4 horizontalPixels;
        /// 网格局部到最终显示像素y的行向量。
        float4 verticalPixels;
        /// 已预乘源色或图片四通道opacity。
        float4 color;
        /// 裁剪边数、BVH节点数、保留零值、裁剪数组起点。
        uint4 counts;
        /// 当前局部pass在最终显示坐标中的像素原点。
        float4 targetOffset;
        /// 世界到局部的逆线性矩阵，按两行存储。
        float4 inverse;
        /// 包围矩形NDC的left/top/right/bottom，仅用于产生片元。
        float4 rasterBounds;
    };
    /// 光栅化只输出片元位置，不对输入三角形逐个做混合。
    struct PAGRaster {
        /// 顶点输出为NDC，片元输入为当前pass像素中心。
        float4 position [[position]];
    };
    /// 每个完整填充绘制一次包围矩形，真实图形覆盖由片元BVH查询决定。
    vertex PAGRaster pagVertex(uint index [[vertex_id]], constant PAGUniforms &uniforms [[buffer(1)]]) {
        const uint corners[6] = {0, 1, 2, 0, 2, 3};
        float2 unit = pagPixelCorner(corners[index]);
        PAGRaster result;
        result.position = float4(mix(uniforms.rasterBounds.xy, uniforms.rasterBounds.zw, unit), 0, 1);
        return result;
    }
    /// 同一填充的联合覆盖只返回一次；空洞或裁剪之外不触发无用混合。
    inline float pagCoverage(float2 pixel, constant PAGUniforms &uniforms, const device float4 *clips,
                              const device PAGCoverageNode *nodes, const device uint *triangles,
                              const device PAGCoverageVertex *vertices) {
        float area = pagMeshArea(pixel - 0.5f, uniforms.horizontalPixels, uniforms.verticalPixels, uniforms.inverse,
                                 vertices, nodes, triangles, uniforms.counts.y, clips + uniforms.counts.w, uniforms.counts.x);
        if (area <= 0) { discard_fragment(); }
        return area;
    }
    /// 已预乘纯色仅乘一次联合覆盖，再由固定管线SrcOver。
    fragment float4 pagSolid(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                             const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                             const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        return uniforms.color * pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
    }
    /// 图片和组纹理共享世界逆变换，按像素中心采样预乘输入，再应用联合覆盖。
    fragment float4 pagImage(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                             const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                             const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                             texture2d<float> image [[texture(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 uv = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        return image.sample(inputSampler, uv) * uniforms.color * area;
    }
    /// 渐变与几何共用实际draw逆变换；局部组先补全局原点，材料不接触coverage的半像素偏移。
    fragment float4 pagGradient(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                constant PAGGradientUniforms &gradient [[buffer(6)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 q = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        return pagGradientSample(q, gradient) * uniforms.color * area;
    }
    /// 双平面在最终片元直接转色，覆盖/图层alpha只乘一次，不创建中间RGBA图像。
    fragment float4 pagVideo(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                             const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                             const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                             constant PAGVideoUniforms &video [[buffer(6)]],
                             texture2d<float> luma [[texture(0)]], texture2d<float> chroma [[texture(1)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 uv = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        float4 coordinates = pagVideoCoordinates(uv, video);
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float3 yuv = float3(luma.sample(inputSampler, coordinates.xy).r, chroma.sample(inputSampler, coordinates.xy).rg);
        bool hasAlpha = video.alphaRegion.z != 0;
        float alphaY = hasAlpha ? luma.sample(inputSampler, coordinates.zw).r : 0;
        return pagVideoColor(yuv, alphaY, hasAlpha) * uniforms.color * area;
    }
    """
}
