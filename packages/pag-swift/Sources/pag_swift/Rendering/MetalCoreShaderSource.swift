/// 随库编译的MSL源码，首次GPU使用才在后台编译；不在播放循环中创建library。
enum MetalShaderSource {
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
    /// MotionTileFilter的Float比例与GLSL floor型mod；先钳边，再镜像，最后只对正phase交错位移。
    struct PAGMotionTileUniforms { float4 centerAndTile; float4 outputAndPhase; float4 mirror; };
    struct PAGTextBulgeMap { float4 horizontal; float4 vertical; };
    inline float2 pagMotionTileCoordinate(float2 outputUV, constant PAGMotionTileUniforms &tile) {
        float2 outputSize = tile.outputAndPhase.xy;
        float2 scaleSize = tile.centerAndTile.zw;
        float2 originSize = 1.0f / outputSize;
        float2 newCenter = float2(0.5f) - originSize / 2.0f + tile.centerAndTile.xy / outputSize;
        float2 newOrigin = newCenter - originSize * scaleSize / 2.0f;
        float2 location = (outputUV - newOrigin) / (originSize * scaleSize);
        float2 target = location - floor(location);
        target = clamp(target, float2(0.005f), float2(0.995f));
        float2 parity = floor(location);
        parity -= 2.0f * floor(parity / 2.0f);
        if (tile.mirror.x != 0.0f) {
            target = parity * (1.0f - target) + abs(parity - 1.0f) * target;
        }
        if (tile.outputAndPhase.z > 0.0f) {
            float phase = tile.outputAndPhase.z - 360.0f * floor(tile.outputAndPhase.z / 360.0f);
            if (tile.outputAndPhase.w != 0.0f) {
                target.x = parity.y * fract(target.x + phase / 360.0f) + abs(parity.y - 1.0f) * target.x;
            } else {
                target.y = parity.x * fract(target.y + phase / 360.0f) + abs(parity.x - 1.0f) * target.y;
            }
        }
        return target;
    }
    inline float4 pagMotionTileSample(float2 outputUV, constant PAGMotionTileUniforms &tile,
                                      texture2d<float> image) {
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        return image.sample(inputSampler, pagMotionTileCoordinate(outputUV, tile));
    }
    /// 图像平铺只改变当前输入采样，已有几何、祖先裁剪和SrcOver保持原路径。
    fragment float4 pagMotionTileImage(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                       const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                       const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                       constant PAGMotionTileUniforms &tile [[buffer(6)]],
                                       texture2d<float> image [[texture(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 uv = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        return pagMotionTileSample(uv, tile, image) * uniforms.color * area;
    }
    /// BulgeFilter先把输出位置映回输入bounds，再沿椭圆内的高度函数反采样。
    struct PAGBulgeUniforms { float4 centerAndRadii; float4 outputRect; float4 heightAndPinning; };
    /// 供独立Bulge与CornerPin后Bulge共用反向坐标；不在此步采样输入材质。
    inline float2 pagBulgeCoordinate(float2 outputUV, constant PAGBulgeUniforms &bulge) {
        float2 target = bulge.outputRect.xy + outputUV * bulge.outputRect.zw;
        float2 point = target - bulge.centerAndRadii.xy;
        float2 normalized = point / bulge.centerAndRadii.zw;
        float distance = dot(normalized, normalized);
        float len = length(point);
        float angle = atan2(point.y, point.x);
        float weight = (1.0f - distance) * atan2(len, sqrt(1.0f - sqrt(len))) / 3.1415926535f;
        if (distance <= 1.0f) {
            target = point - bulge.heightAndPinning.x * weight * float2(cos(angle), sin(angle))
                   + bulge.centerAndRadii.xy;
        }
        if (bulge.heightAndPinning.y != 0.0f) {
            target = clamp(target, float2(0.005f), float2(0.995f));
        }
        return target;
    }
    inline float4 pagBulgeSample(float2 outputUV, constant PAGBulgeUniforms &bulge,
                                  texture2d<float> image) {
        float2 target = pagBulgeCoordinate(outputUV, bulge);
        float2 inside = abs(step(float2(1.0f), target) - float2(1.0f)) * step(float2(0.0f), target);
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        return image.sample(inputSampler, target) * inside.x * inside.y;
    }
    /// 原图已有输入纹理，Bulge只替换本次根pass的片元取样。
    fragment float4 pagBulgeImage(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                   const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                   const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                   constant PAGBulgeUniforms &bulge [[buffer(6)]],
                                   texture2d<float> image [[texture(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 uv = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        return pagBulgeSample(uv, bulge, image) * uniforms.color * area;
    }
    /// 文字先在紧致透明纹理组合，Bulge继续以父合成输入域求值，再映入该纹理采样。
    fragment float4 pagTextBulgeImage(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                     const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                     const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                     constant PAGBulgeUniforms &bulge [[buffer(6)]],
                                     constant PAGTextBulgeMap &map [[buffer(11)]],
                                     texture2d<float> image [[texture(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 outputUV = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        float2 source = pagBulgeCoordinate(outputUV, bulge);
        if (any(source < float2(0.0f)) || any(source >= float2(1.0f))) { discard_fragment(); }
        float3 q = float3(source, 1.0f);
        float2 uv = float2(dot(map.horizontal.xyz, q), dot(map.vertical.xyz, q));
        if (any(uv < float2(0.0f)) || any(uv >= float2(1.0f))) { discard_fragment(); }
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        return image.sample(inputSampler, uv) * uniforms.color * area;
    }
    /// 四角AABB内反投影前一效果的单位纹理域；凸性和退化已在CPU准备阶段检查。
    struct PAGCornerPinUniforms { float4 outputRect; float4 inverseX; float4 inverseY; float4 inverseW; };
    inline bool pagCornerPinUV(float2 outputUV, constant PAGCornerPinUniforms &corner,
                               thread float2 &sourceUV) {
        float2 point = corner.outputRect.xy + outputUV * corner.outputRect.zw;
        float3 homogeneous = float3(point, 1.0f);
        float denominator = dot(corner.inverseW.xyz, homogeneous);
        if (!isfinite(denominator) || abs(denominator) < 0.000001f) { return false; }
        sourceUV = float2(dot(corner.inverseX.xyz, homogeneous),
                          dot(corner.inverseY.xyz, homogeneous)) / denominator;
        return all(isfinite(sourceUV)) && all(sourceUV >= float2(0.0f)) &&
               all(sourceUV <= float2(1.0f));
    }
    /// 独立tag58只在当前drawable采样原输入，不创建输出图像。
    fragment float4 pagCornerPinImage(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                      const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                      const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                      constant PAGCornerPinUniforms &corner [[buffer(11)]],
                                      texture2d<float> image [[texture(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 outputUV = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        float2 sourceUV;
        if (!pagCornerPinUV(outputUV, corner, sourceUV)) { discard_fragment(); }
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        return image.sample(inputSampler, sourceUV) * uniforms.color * area;
    }
    /// 上游先平铺再投影；逆向采样先求四角输入，后调用既有平铺公式。
    fragment float4 pagMotionTileCornerPinImage(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                                const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                                const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                                constant PAGMotionTileUniforms &tile [[buffer(6)]],
                                                constant PAGCornerPinUniforms &corner [[buffer(11)]],
                                                texture2d<float> image [[texture(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 outputUV = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        float2 tileUV;
        if (!pagCornerPinUV(outputUV, corner, tileUV)) { discard_fragment(); }
        return pagMotionTileSample(tileUV, tile, image) * uniforms.color * area;
    }
    /// 上游先四角投影再Bulge；逆向采样先求Bulge输入，再反投影原纹理。
    fragment float4 pagCornerPinBulgeImage(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                           const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                           const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                           constant PAGBulgeUniforms &bulge [[buffer(6)]],
                                           constant PAGCornerPinUniforms &corner [[buffer(11)]],
                                           texture2d<float> image [[texture(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 outputUV = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        float2 cornerUV = pagBulgeCoordinate(outputUV, bulge);
        float2 sourceUV;
        if (!pagCornerPinUV(cornerUV, corner, sourceUV)) { discard_fragment(); }
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        return image.sample(inputSampler, sourceUV) * uniforms.color * area;
    }
    /// 阴影颜色只由样式RGB/opacity决定；源内容的预乘alpha保留内部重叠的真实合成结果。
    fragment float4 pagShadowImage(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                   const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                   const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                   texture2d<float> image [[texture(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 uv = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_zero, filter::linear);
        return uniforms.color * (image.sample(inputSampler, uv).a * area);
    }
    /// 羽化层先组合内容，再由同尺寸局部mask表面只乘一次alpha，不能逐子图元提前裁剪。
    fragment float4 pagFeatherImage(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                    const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                    const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                    texture2d<float> content [[texture(0)]], texture2d<float> maskImage [[texture(1)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 uv = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        return content.sample(inputSampler, uv) * (maskImage.sample(inputSampler, uv).a * uniforms.color * area);
    }
    /// 轨道遮罩源先独立SrcOver为预乘颜色；亮度来自预乘RGB，已包含源自身alpha。
    fragment float4 pagTrackMatteImage(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                       const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                       const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                       constant uint &mode [[buffer(11)]],
                                       texture2d<float> content [[texture(0)]], texture2d<float> maskImage [[texture(1)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 uv = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 mask = maskImage.sample(inputSampler, uv);
        float factor = mode >= 3 ? dot(mask.rgb, float3(0.2126f, 0.7152f, 0.0722f)) : mask.a;
        if (mode == 2 || mode == 4) { factor = 1.0f - factor; }
        return content.sample(inputSampler, uv) * (factor * uniforms.color * area);
    }
    /// 效果专用矩形拷贝只持有预先计算的NDC范围，不走通用几何BVH。
    struct PAGFeatherCopyUniforms { float4 bounds; };
    /// 直接把局部图片四角映到目标附件，纹理坐标与单位方形同步插值。
    struct PAGFeatherCopyRaster { float4 position [[position]]; float2 uv; };
    vertex PAGFeatherCopyRaster pagFeatherCopyVertex(uint index [[vertex_id]],
                                                     constant PAGFeatherCopyUniforms &uniforms [[buffer(0)]]) {
        const uint corners[6] = {0, 1, 2, 0, 2, 3};
        float2 unit = pagPixelCorner(corners[index]);
        PAGFeatherCopyRaster result;
        result.position = float4(mix(uniforms.bounds.xy, uniforms.bounds.zw, unit), 0, 1);
        result.uv = unit;
        return result;
    }
    /// 默认SrcOver由管线处理；源项的路径覆盖和opacity已烘在本项局部alpha图。
    fragment float4 pagFeatherCopy(PAGFeatherCopyRaster in [[stage_in]], texture2d<float> source [[texture(0)]]) {
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        return source.sample(inputSampler, in.uv);
    }
    /// 源尺寸、半核半径/方向和目标到源的像素偏移按两个16字节向量固定布局。
    struct PAGFeatherBlurUniforms { uint4 sourceAndKernel; int4 shift; };
    /// 直接按整数像素中心做一维卷积；超出源图像边界的样本是透明Decal。
    fragment float4 pagFeatherBlur(PAGFeatherCopyRaster in [[stage_in]],
                                   texture2d<float> source [[texture(0)]],
                                   constant float *weights [[buffer(1)]],
                                   constant PAGFeatherBlurUniforms &blur [[buffer(2)]]) {
        int2 base = int2(floor(in.position.xy)) - blur.shift.xy;
        int2 step = blur.sourceAndKernel.w == 0 ? int2(1, 0) : int2(0, 1);
        int radius = int(blur.sourceAndKernel.z);
        float4 sum = float4(0);
        for (int offset = -radius; offset <= radius; ++offset) {
            int2 p = base + step * offset;
            if (p.x >= 0 && p.y >= 0 && p.x < int(blur.sourceAndKernel.x) && p.y < int(blur.sourceAndKernel.y)) {
                sum += source.read(uint2(p)) * weights[abs(offset)];
            }
        }
        return sum;
    }
    /// 高sigma两侧只做线性Decal重采样；坐标是源图像的像素中心而非最终画面尺寸。
    struct PAGFeatherResampleUniforms { float4 transform; float4 sourceSize; };
    fragment float4 pagFeatherResample(PAGFeatherCopyRaster in [[stage_in]],
                                       texture2d<float> source [[texture(0)]],
                                       constant PAGFeatherResampleUniforms &uniforms [[buffer(1)]]) {
        float2 sourcePixel = in.position.xy * uniforms.transform.xy + uniforms.transform.zw;
        float2 uv = sourcePixel / uniforms.sourceSize.xy;
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_zero, filter::linear);
        return source.sample(inputSampler, uv);
    }
    /// 源宽高/真实扩散半径与源图在输出附件的整数起点；w=1时再取半半径圈。
    struct PAGShadowStrokeUniforms { float4 sourceAndRadius; float4 originAndMode; };
    /// SolidStrokeFilter的Normal/Thick椭圆采样只生成alpha；样式颜色与opacity在根pass应用。
    fragment float4 pagShadowStroke(PAGFeatherCopyRaster in [[stage_in]],
                                     texture2d<float> source [[texture(0)]],
                                     constant PAGShadowStrokeUniforms &stroke [[buffer(1)]]) {
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_zero, filter::linear);
        float2 size = stroke.sourceAndRadius.xy;
        float2 uv = (floor(in.position.xy) - stroke.originAndMode.xy + 0.5f) / size;
        float center = source.sample(inputSampler, uv).a;
        if (center > 0.0f) { return float4(1.0f); }
        float2 radius = min(stroke.sourceAndRadius.zw, float2(25.0f)) / size;
        if (radius.x == 0.0f && radius.y == 0.0f) { return float4(0.0f); }
        for (int index = 0; index <= 16; ++index) {
            float angle = float(index) * (11.25f * 3.1415926535f / 180.0f);
            float2 delta = float2(cos(angle) * radius.x, sin(angle) * radius.y);
            if (source.sample(inputSampler, uv + delta).a > 0.0f ||
                source.sample(inputSampler, uv + float2(delta.x, -delta.y)).a > 0.0f) {
                return float4(1.0f);
            }
            if (stroke.originAndMode.z != 0.0f &&
                (source.sample(inputSampler, uv + delta * 0.5f).a > 0.0f ||
                 source.sample(inputSampler, uv + float2(delta.x, -delta.y) * 0.5f).a > 0.0f)) {
                return float4(1.0f);
            }
        }
        return float4(0.0f);
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
    /// 只有超过解析容量的渐变读取小输入表；几何覆盖与根drawable不变。
    fragment float4 pagGradientTexture(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                       const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                       const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                       constant PAGGradientUniforms &gradient [[buffer(6)]],
                                       texture2d<float> lookup [[texture(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 q = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        return pagGradientTextureSample(q, gradient, lookup) * uniforms.color * area;
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
        return pagVideoColor(yuv, alphaY, hasAlpha, video.matrixSelection.x) * uniforms.color * area;
    }
    /// 单mask直接查询有限网格；补集用1−coverage，不用有限包围框代替无限外部。
    struct PAGMaskUniforms {
        float4 horizontalPixels;
        float4 verticalPixels;
        float4 inverse;
        uint4 options;
    };
    inline float pagMaskedCoverage(float2 pixel, constant PAGUniforms &uniforms,
                                   const device float4 *clips, const device PAGCoverageNode *nodes,
                                   const device uint *triangles, const device PAGCoverageVertex *vertices,
                                   constant PAGMaskUniforms &mask, const device PAGCoverageNode *maskNodes,
                                   const device uint *maskTriangles, const device PAGCoverageVertex *maskVertices) {
        float area = pagCoverage(pixel, uniforms, clips, nodes, triangles, vertices);
        float finite = pagMeshArea(pixel - 0.5f, mask.horizontalPixels, mask.verticalPixels, mask.inverse,
                                   maskVertices, maskNodes, maskTriangles, mask.options.x, clips, 0);
        float coverage = area * (mask.options.y != 0 ? 1.0f - finite : finite);
        if (coverage <= 0) { discard_fragment(); }
        return coverage;
    }
    /// 外层普通路径覆盖与轨道源因子只在已经合成的拥有者颜色上各乘一次。
    fragment float4 pagMaskedTrackMatteImage(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                             const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                             const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                             constant PAGMaskUniforms &mask [[buffer(7)]], const device PAGCoverageNode *maskNodes [[buffer(8)]],
                                             const device uint *maskTriangles [[buffer(9)]], const device PAGCoverageVertex *maskVertices [[buffer(10)]],
                                             constant uint &mode [[buffer(11)]],
                                             texture2d<float> content [[texture(0)]], texture2d<float> maskImage [[texture(1)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagMaskedCoverage(pixel, uniforms, clips, nodes, triangles, vertices,
                                       mask, maskNodes, maskTriangles, maskVertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 uv = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 source = maskImage.sample(inputSampler, uv);
        float factor = mode >= 3 ? dot(source.rgb, float3(0.2126f, 0.7152f, 0.0722f)) : source.a;
        if (mode == 2 || mode == 4) { factor = 1.0f - factor; }
        return content.sample(inputSampler, uv) * (factor * uniforms.color * area);
    }
    /// 纯色每次实际绘制分别乘mask，不先把整层合成成一张颜色图。
    fragment float4 pagMaskedSolid(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                   const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                   const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                   constant PAGMaskUniforms &mask [[buffer(7)]], const device PAGCoverageNode *maskNodes [[buffer(8)]],
                                   const device uint *maskTriangles [[buffer(9)]], const device PAGCoverageVertex *maskVertices [[buffer(10)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        return uniforms.color * pagMaskedCoverage(pixel, uniforms, clips, nodes, triangles, vertices,
                                                  mask, maskNodes, maskTriangles, maskVertices);
    }
    /// 成功Picture只形成一次纹理draw，资源miss则其原始图元各自消费mask。
    fragment float4 pagMaskedImage(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                   const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                   const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                   constant PAGMaskUniforms &mask [[buffer(7)]], const device PAGCoverageNode *maskNodes [[buffer(8)]],
                                   const device uint *maskTriangles [[buffer(9)]], const device PAGCoverageVertex *maskVertices [[buffer(10)]],
                                   texture2d<float> image [[texture(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagMaskedCoverage(pixel, uniforms, clips, nodes, triangles, vertices,
                                       mask, maskNodes, maskTriangles, maskVertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 uv = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        return image.sample(inputSampler, uv) * uniforms.color * area;
    }
    /// 内层普通路径和外层普通路径各求一次非零覆盖，只对同一图像实际draw相乘。
    fragment float4 pagDoubleMaskedImage(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                          const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                          const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                          constant PAGMaskUniforms &inner [[buffer(7)]], const device PAGCoverageNode *innerNodes [[buffer(8)]],
                                          const device uint *innerTriangles [[buffer(9)]], const device PAGCoverageVertex *innerVertices [[buffer(10)]],
                                          constant PAGMaskUniforms &outer [[buffer(12)]], const device PAGCoverageNode *outerNodes [[buffer(13)]],
                                          const device uint *outerTriangles [[buffer(14)]], const device PAGCoverageVertex *outerVertices [[buffer(15)]],
                                          texture2d<float> image [[texture(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagMaskedCoverage(pixel, uniforms, clips, nodes, triangles, vertices,
                                       inner, innerNodes, innerTriangles, innerVertices);
        float outerArea = pagMeshArea(pixel - 0.5f, outer.horizontalPixels, outer.verticalPixels, outer.inverse,
                                       outerVertices, outerNodes, outerTriangles, outer.options.x, clips, 0);
        area *= outerArea;
        if (area <= 0) { discard_fragment(); }
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 uv = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        return image.sample(inputSampler, uv) * uniforms.color * area;
    }
    /// 预合成祖先普通蒙版在平铺完成的最终片元相乘，不改变Image层无自身mask的输入合同。
    fragment float4 pagMaskedMotionTileImage(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                             const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                             const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                             constant PAGMotionTileUniforms &tile [[buffer(6)]],
                                             constant PAGMaskUniforms &mask [[buffer(7)]], const device PAGCoverageNode *maskNodes [[buffer(8)]],
                                             const device uint *maskTriangles [[buffer(9)]], const device PAGCoverageVertex *maskVertices [[buffer(10)]],
                                             texture2d<float> image [[texture(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagMaskedCoverage(pixel, uniforms, clips, nodes, triangles, vertices,
                                       mask, maskNodes, maskTriangles, maskVertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 uv = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        return pagMotionTileSample(uv, tile, image) * uniforms.color * area;
    }
    /// 祖先普通mask覆盖作用于已凸出的输出，不回写到效果输入纹理。
    fragment float4 pagMaskedBulgeImage(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                         const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                         const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                         constant PAGBulgeUniforms &bulge [[buffer(6)]],
                                         constant PAGMaskUniforms &mask [[buffer(7)]], const device PAGCoverageNode *maskNodes [[buffer(8)]],
                                         const device uint *maskTriangles [[buffer(9)]], const device PAGCoverageVertex *maskVertices [[buffer(10)]],
                                         texture2d<float> image [[texture(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagMaskedCoverage(pixel, uniforms, clips, nodes, triangles, vertices,
                                       mask, maskNodes, maskTriangles, maskVertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 uv = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        return pagBulgeSample(uv, bulge, image) * uniforms.color * area;
    }
    /// 渐变材料在mask覆盖之后仍只求值一次，不改变其局部坐标与色标。
    fragment float4 pagMaskedGradient(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                      const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                      const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                      constant PAGGradientUniforms &gradient [[buffer(6)]],
                                      constant PAGMaskUniforms &mask [[buffer(7)]], const device PAGCoverageNode *maskNodes [[buffer(8)]],
                                      const device uint *maskTriangles [[buffer(9)]], const device PAGCoverageVertex *maskVertices [[buffer(10)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagMaskedCoverage(pixel, uniforms, clips, nodes, triangles, vertices,
                                       mask, maskNodes, maskTriangles, maskVertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 q = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        return pagGradientSample(q, gradient) * uniforms.color * area;
    }
    /// 子项蒙版覆盖与纹理渐变只在本次实际draw相乘，不另造整帧附件。
    fragment float4 pagMaskedGradientTexture(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                             const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                             const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                             constant PAGGradientUniforms &gradient [[buffer(6)]],
                                             constant PAGMaskUniforms &mask [[buffer(7)]], const device PAGCoverageNode *maskNodes [[buffer(8)]],
                                             const device uint *maskTriangles [[buffer(9)]], const device PAGCoverageVertex *maskVertices [[buffer(10)]],
                                             texture2d<float> lookup [[texture(0)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagMaskedCoverage(pixel, uniforms, clips, nodes, triangles, vertices,
                                       mask, maskNodes, maskTriangles, maskVertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 q = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        return pagGradientTextureSample(q, gradient, lookup) * uniforms.color * area;
    }
    /// 双平面视频不经RGBA中转，mask仍在最终片元只乘一次预乘颜色。
    fragment float4 pagMaskedVideo(PAGRaster in [[stage_in]], constant PAGUniforms &uniforms [[buffer(1)]],
                                   const device float4 *clips [[buffer(2)]], const device PAGCoverageNode *nodes [[buffer(3)]],
                                   const device uint *triangles [[buffer(4)]], const device PAGCoverageVertex *vertices [[buffer(5)]],
                                   constant PAGVideoUniforms &video [[buffer(6)]],
                                   constant PAGMaskUniforms &mask [[buffer(7)]], const device PAGCoverageNode *maskNodes [[buffer(8)]],
                                   const device uint *maskTriangles [[buffer(9)]], const device PAGCoverageVertex *maskVertices [[buffer(10)]],
                                   texture2d<float> luma [[texture(0)]], texture2d<float> chroma [[texture(1)]]) {
        float2 pixel = in.position.xy + uniforms.targetOffset.xy;
        float area = pagMaskedCoverage(pixel, uniforms, clips, nodes, triangles, vertices,
                                       mask, maskNodes, maskTriangles, maskVertices);
        float2 relative = pixel - float2(uniforms.horizontalPixels.z, uniforms.verticalPixels.z);
        float2 uv = float2(dot(uniforms.inverse.xy, relative), dot(uniforms.inverse.zw, relative));
        float4 coordinates = pagVideoCoordinates(uv, video);
        constexpr sampler inputSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float3 yuv = float3(luma.sample(inputSampler, coordinates.xy).r, chroma.sample(inputSampler, coordinates.xy).rg);
        bool hasAlpha = video.alphaRegion.z != 0;
        float alphaY = hasAlpha ? luma.sample(inputSampler, coordinates.zw).r : 0;
        return pagVideoColor(yuv, alphaY, hasAlpha, video.matrixSelection.x) * uniforms.color * area;
    }
    """ + MetalScreenShaderSource.source + MetalMotionBlurShaderSource.source + MetalGlowShaderSource.source
        + MetalFastBlurShaderSource.source + MetalTileGlowShaderSource.source
        + MetalGradientOverlayShaderSource.source
}
