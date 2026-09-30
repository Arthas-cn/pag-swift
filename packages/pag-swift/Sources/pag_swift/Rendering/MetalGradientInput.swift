/// 渐变在GPU准备阶段的最终分支；退化使用已有纯色管线，仍保留完整预乘RGBA。
enum MetalGradientInput {
    /// 已乘自身alpha，尚未乘paint/组透明度的单色。
    case solid(SIMD4<Float>)
    /// 固定大小的解析常量，不保活或上传源stop数组。
    case analytic(MetalGradientUniforms)

    /// 在真实几何和裁剪非空后准备材料；预算、取消、精度和不支持错误不返回半份输入。
    static func make(_ gradient: PreparedGradient, origin: ScenePoint,
                     budget: inout MetalFrameBudget) throws -> MetalGradientInput {
        try budget.reserve(512)
        switch try GradientTransform.layout(for: gradient, origin: origin) {
        case .solid(let color):
            return .solid(SIMD4(color.x * color.w, color.y * color.w, color.z * color.w, color.w))
        case .mapped(let matrix):
            guard case .analytic(let program) = gradient.colorizer.result else {
                throw PAGError.renderingFailure("gradientPrecision")
            }
            return .analytic(try MetalGradientUniforms(matrix: matrix, gradient: gradient, program: program))
        }
    }
}

/// 16字节对齐的单段参数；MSL用同样的三个float4，不上传Swift数组的引用内存。
struct MetalGradientInterval {
    /// 区间仿射scale；Single分支复用为起始色，保持独立插值算式。
    let scale: SIMD4<Float>
    /// 区间仿射bias；Single分支复用为结束色。
    let bias: SIMD4<Float>
    /// x为严格小于比较的右边界，剩余分量恒为零。
    let limits: SIMD4<Float>

    /// 未使用槽位固定清零，不让Swift填充或指针内容进入GPU。
    static let zero = MetalGradientInterval(scale: .zero, bias: .zero, limits: .zero)
}

/// 与PAGGradientUniforms逐字段一致的464字节值；映射已包含网格原点补偿。
struct MetalGradientUniforms {
    /// 从网格相对坐标到unit.x的a/c/tx，w固定为零。
    let horizontal: SIMD4<Float>
    /// 从网格相对坐标到unit.y的b/d/ty，w固定为零。
    let vertical: SIMD4<Float>
    /// t<=0时使用的未预乘原首色，不能用剥除hardstop后的颜色替换。
    let first: SIMD4<Float>
    /// t>=1时使用的未预乘原末色。
    let last: SIMD4<Float>
    /// 布局0线性/1径向、程序0Single/1Intervals、有效段数及保留零值。
    let header: SIMD4<UInt32>
    /// 至多八段内联存储；尾部槽位恒为零，与MSL固定数组相同。
    let intervals: (MetalGradientInterval, MetalGradientInterval, MetalGradientInterval, MetalGradientInterval,
                    MetalGradientInterval, MetalGradientInterval, MetalGradientInterval, MetalGradientInterval)

    /// 只打包已经编译的有界程序；原始stop数量不会影响每draw成本，非法段数明确失败。
    init(matrix: GradientTransform, gradient: PreparedGradient, program: GradientColorizerProgram) throws {
        horizontal = SIMD4(matrix.a, matrix.c, matrix.tx, 0)
        vertical = SIMD4(matrix.b, matrix.d, matrix.ty, 0)
        first = gradient.colorizer.first
        last = gradient.colorizer.last
        switch program {
        case let .single(start, end):
            header = SIMD4(UInt32(gradient.kind.rawValue), 0, 1, 0)
            intervals = (MetalGradientInterval(scale: start, bias: end, limits: .zero),
                         .zero, .zero, .zero, .zero, .zero, .zero, .zero)
        case .intervals(let values):
            guard (1...8).contains(values.count) else { throw PAGError.renderingFailure("gradientPrecision") }
            header = SIMD4(UInt32(gradient.kind.rawValue), 1, UInt32(values.count), 0)
            intervals = (Self.pack(values, at: 0), Self.pack(values, at: 1), Self.pack(values, at: 2), Self.pack(values, at: 3),
                         Self.pack(values, at: 4), Self.pack(values, at: 5), Self.pack(values, at: 6), Self.pack(values, at: 7))
        }
    }

    /// 复制一个有界区间，缺省槽位清零；只由已检查段数的初始化器调用。
    private static func pack(_ values: [GradientColorInterval], at index: Int) -> MetalGradientInterval {
        guard values.indices.contains(index) else { return .zero }
        let value = values[index]
        return MetalGradientInterval(scale: value.scale, bias: value.bias, limits: SIMD4(value.upperBound, 0, 0, 0))
    }
}
