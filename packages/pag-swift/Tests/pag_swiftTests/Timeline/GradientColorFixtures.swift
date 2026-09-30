import Testing
@testable import pag_swift

/// 渐变纯语义数值夹具，不产生PAG字节或冒充真实导出文件。
enum GradientColorFixtures {
    /// RGB数值域中的红端值，即使对应alpha为零也保留。
    static let red = SceneColor(red: 255, green: 0, blue: 0)
    /// RGB数值域中的蓝端值，用于透明度与未预乘插值。
    static let blue = SceneColor(red: 0, green: 0, blue: 255)
    /// 双段区分用的绿色中值。
    static let green = SceneColor(red: 0, green: 255, blue: 0)

    /// 按显式位置构造已经满足非空/升序的原始双表；中点只控制非末项。
    static func colors(rgb: [(Float, SceneColor)] = [(0, red), (1, blue)],
                       alpha: [(Float, UInt8)] = [(0, 255), (1, 255)],
                       colorMidpoint: Float = 0.5, alphaMidpoint: Float = 0.5) -> SourceGradientColors {
        SourceGradientColors(alphaStops: alpha.map { .init(position: $0.0, midpoint: alphaMidpoint, opacity: $0.1) },
                             colorStops: rgb.map { .init(position: $0.0, midpoint: colorMidpoint, color: $0.1) })
    }

    /// 使用独立充足预算编译完整材料，失败沿用生产错误。
    static func compile(_ source: SourceGradientColors) throws -> PreparedGradientColorizer {
        var budget = FramePlanBudget(limit: 64 * 1024 * 1024)
        return try GradientColorizer.prepare(source, budget: &budget)
    }

    /// 测试端按声明的Float程序取未预乘RGBA，与手算金值比较；这不是生产像素读取或颜色渲染器。
    static func sample(_ value: PreparedGradientColorizer, at t: Float) throws -> SIMD4<Float> {
        if t <= 0 { return value.first }
        if t >= 1 { return value.last }
        switch value.result {
        case .singleColor: return value.first
        case .analytic(.single(let first, let last)): return (1 - t) * first + t * last
        case .analytic(.intervals(let intervals)):
            let index = intervals.firstIndex { t < $0.upperBound } ?? intervals.count - 1
            return t * intervals[index].scale + intervals[index].bias
        case .requiresTexture: throw PAGError.unsupportedFeature("gradientTextureColorizer")
        case .invalidPrecision: throw PAGError.renderingFailure("gradientPrecision")
        }
    }

    /// 当前测试不需要几何，固定端点及变换仅用于颜色程序复用入口。
    static func source(_ colors: SourceProperty<SourceGradientColors>) -> SourceGradient {
        SourceGradient(kind: .linear, start: .init(constant: .zero), end: .init(constant: ScenePoint(x: 100, y: 0)),
                       colors: colors, opacity: .init(constant: 255))
    }
}
