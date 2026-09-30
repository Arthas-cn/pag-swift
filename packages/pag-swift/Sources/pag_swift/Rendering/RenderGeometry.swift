import Foundation

/// 渲染准备后的不可变填充网格；相邻三角形只共享边，不重复覆盖填充内部。
final class RenderMesh: Sendable {
    /// 网格相对源坐标的原点；编码时必须先补回此平移，再应用图层矩阵。
    let origin: ScenePoint
    /// 每三个点组成一个三角形，坐标相对 origin；空数组表示无填充面积。
    let vertices: [ScenePoint]
    /// 网格与数组的保守留存计费，不表示 GPU 缓冲或 allocator 实际驻留量。
    var estimatedBytes: Int { 128 + vertices.count * 32 }

    /// 接收已完成验证、预算检查和 nonzero 分解的三角形，不在此处再次复制。
    init(origin: ScenePoint, vertices: [ScenePoint]) {
        self.origin = origin
        self.vertices = vertices
    }
}

/// 按显示变换最大伸长量向上取整的精度档；平移不进入键，缩小时不降低基础精度。
struct GeometryPrecision: Sendable, Hashable {
    /// 2 的幂次，零表示源坐标中每 1/8 单位的误差界。
    let exponent: Int
    /// 源坐标中允许的曲线弦段误差，经过最终变换后不超过 1/8 像素。
    var tolerance: Double { Double(sign: .plus, exponent: -3 - exponent, significand: 1) }

    /// 计算有限线性变换的最大奇异值；极端精度无法表示时抛资源错误。
    init(transform: SceneAffine) throws {
        let stretch = try Self.maximumStretch(transform)
        let scale = max(1, stretch)
        let power = Double(sign: .plus, exponent: scale.exponent, significand: 1)
        exponent = scale == power ? scale.exponent : scale.exponent + 1
        guard exponent <= 1023, tolerance > 0 else {
            throw PAGError.resourceLimitExceeded("geometryPrecision")
        }
    }

    /// 用归一化的 AᵀA 特征值求伸长量，避免平方放大导致本可表示的矩阵溢出。
    static func maximumStretch(_ matrix: SceneAffine) throws -> Double {
        let scale = max(abs(matrix.a), abs(matrix.b), abs(matrix.c), abs(matrix.d))
        guard scale > 0 else { return 0 }
        let a = matrix.a / scale, b = matrix.b / scale
        let c = matrix.c / scale, d = matrix.d / scale
        let first = a * a + b * b, second = c * c + d * d
        let dot = a * c + b * d
        let value = sqrt((first + second + hypot(first - second, 2 * dot)) * 0.5) * scale
        guard value.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        return value
    }
}

/// 单次网格准备的内存与工作量限制；增长前计费，失败不返回部分网格。
struct GeometryBudget {
    /// 累计逻辑字节计费，包含中间数组和输出，不承诺等于进程峰值。
    private var bytes: FramePlanBudget
    /// 正工作量上限，用来限制自交扫描与恶意细分。
    let maximumWork: Int
    /// 每条曲线允许的细分深度，0...32；测试可缩小以验证失败语义。
    let maximumDepth: Int
    /// 已执行或即将执行的逻辑工作量，不会超过 maximumWork。
    private(set) var work = 0

    /// 使用有界默认策略；非法策略抛 invalidArgument，取消立即传播。
    init(maximumBytes: Int = 64 * 1024 * 1024, maximumWork: Int = 16_777_216,
         maximumDepth: Int = 32) throws {
        try Task.checkCancellation()
        guard maximumBytes > 0, maximumWork > 0, (0...32).contains(maximumDepth) else {
            throw PAGError.invalidArgument("geometryLimits")
        }
        bytes = FramePlanBudget(limit: maximumBytes, resourceName: "maximumRenderGeometryBytes")
        self.maximumWork = maximumWork
        self.maximumDepth = maximumDepth
    }

    /// 在数组增长前预留保守成本；乘法溢出与超额统一报告资源限制。
    mutating func reserve(_ count: Int = 1, stride: Int) throws {
        try bytes.reserve(count: count, stride: stride)
    }

    /// 为扫描、曲线访问或排序预留工作量；每次都检查取消，避免长循环继续消耗资源。
    mutating func consume(_ count: Int = 1) throws {
        try Task.checkCancellation()
        guard count >= 0, count <= maximumWork - work else {
            throw PAGError.resourceLimitExceeded("maximumRenderGeometryWork")
        }
        work += count
    }

    /// 标准排序不能中途抛错，先按 n×ceil(log2(n)) 计费，并由调用方在排序后检查取消。
    mutating func sorting(_ count: Int) throws {
        guard count > 1 else { return }
        let levels = Int.bitWidth - (count - 1).leadingZeroBitCount
        let charge = count.multipliedReportingOverflow(by: levels)
        guard !charge.overflow else { throw PAGError.resourceLimitExceeded("maximumRenderGeometryWork") }
        try consume(charge.partialValue)
    }
}

/// 只提供几何准备需要的有限数值运算，不把精度失败解释为空路径。
enum GeometryMath {
    /// 接受有限点，否则让调用方中止本次渲染准备。
    static func checked(_ point: ScenePoint) throws -> ScenePoint {
        guard point.x.isFinite, point.y.isFinite else { throw PAGError.renderingFailure("geometryNonFinite") }
        return point
    }

    /// 先分别减半再相加，防止两个同号大坐标求中点时溢出。
    static func midpoint(_ first: ScenePoint, _ second: ScenePoint) -> ScenePoint {
        ScenePoint(x: first.x * 0.5 + second.x * 0.5, y: first.y * 0.5 + second.y * 0.5)
    }

    /// 到有限弦段的距离；不能只测无限直线，否则共线的回折曲线会被错误消掉。
    static func distance(_ point: ScenePoint, to start: ScenePoint, _ end: ScenePoint) throws -> Double {
        let dx = end.x - start.x, dy = end.y - start.y
        let px = point.x - start.x, py = point.y - start.y
        let length = hypot(dx, dy)
        guard length.isFinite, px.isFinite, py.isFinite else { throw PAGError.renderingFailure("geometryNonFinite") }
        guard length > 0 else {
            let result = hypot(px, py)
            guard result.isFinite else { throw PAGError.renderingFailure("geometryNonFinite") }
            return result
        }
        let ux = dx / length, uy = dy / length
        let projection = px * ux + py * uy
        let result: Double
        if projection <= 0 { result = hypot(px, py) }
        else if projection >= length { result = hypot(point.x - end.x, point.y - end.y) }
        else { result = abs(px * uy - py * ux) }
        guard result.isFinite else { throw PAGError.renderingFailure("geometryNonFinite") }
        return result
    }
}
