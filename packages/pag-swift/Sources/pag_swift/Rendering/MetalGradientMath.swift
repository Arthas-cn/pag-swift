/// 生产片元与GPU数值测试共用的解析渐变内核，不创建纹理或执行CPU像素读取。
enum MetalGradientMath {
    /// 固定464字节常量布局；颜色先在未预乘域插值，再一次预乘自身alpha。
    static let source = """
    /// 一个解析区间，固定三个float4与Swift内联值一致。
    struct PAGGradientInterval {
        /// 仿射scale，Single时保存起始色。
        float4 scale;
        /// 仿射bias，Single时保存结束色。
        float4 bias;
        /// x是右边界，其余分量保留。
        float4 limits;
    };
    /// 从网格局部到渐变unit的映射及最多八段颜色程序。
    struct PAGGradientUniforms {
        /// unit.x的a/c/tx。
        float4 horizontal;
        /// unit.y的b/d/ty。
        float4 vertical;
        /// 原首边色，未预乘。
        float4 first;
        /// 原末边色，未预乘。
        float4 last;
        /// 类型、程序分支、有效段数及保留值。
        uint4 header;
        /// 固定容量，热路径与源stop数量无关。
        PAGGradientInterval intervals[8];
    };
    /// 端点取原边色，段界等号进入右段；调用方已经拒绝没有定义末端的程序。
    inline float4 pagGradientColor(float t, constant PAGGradientUniforms &gradient) {
        if (t <= 0) { return gradient.first; }
        if (t >= 1) { return gradient.last; }
        if (gradient.header.y == 0) {
            return (1 - t) * gradient.intervals[0].scale + t * gradient.intervals[0].bias;
        }
        uint index = gradient.header.z - 1;
        // 最后区间作为源码解析分支的末段；此前各段只接受严格小于。
        for (uint i = 0; i + 1 < gradient.header.z; ++i) {
            if (t < gradient.intervals[i].limits.x) { index = i; break; }
        }
        return t * gradient.intervals[index].scale + gradient.intervals[index].bias;
    }
    /// q来自实际draw逆矩阵，原点已经在CPU补偿，不能在这里重复相加或移动半像素。
    inline float4 pagGradientSample(float2 q, constant PAGGradientUniforms &gradient) {
        float2 unit = float2(dot(gradient.horizontal.xy, q) + gradient.horizontal.z,
                             dot(gradient.vertical.xy, q) + gradient.vertical.z);
        float t = gradient.header.x == 0 ? unit.x + 1e-5f : length(unit);
        float4 color = pagGradientColor(t, gradient);
        color.rgb *= color.a;
        return color;
    }
    """
}
