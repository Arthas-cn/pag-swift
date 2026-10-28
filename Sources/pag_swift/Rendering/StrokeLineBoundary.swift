import Foundation

/// 源Float描边的局部数值操作；归一化按固定SkPoint先用Double求比例，再存回Float。
enum StrokeLineMath {
    /// 将接纳后的坐标变成源Float点；放大政策仍不能接纳不可表示值。
    static func point(_ value: ScenePoint) throws -> SIMD2<Float> {
        let result = SIMD2(Float(value.x), Float(value.y))
        guard result.x.isFinite, result.y.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        return result
    }

    /// 源setLength的零向量或非有限结果返回nil，不把它误认为有效单位切向。
    static func scaled(_ value: SIMD2<Float>, length: Float) -> SIMD2<Float>? {
        let x = Double(value.x), y = Double(value.y)
        let scale = Double(length) / sqrt(x * x + y * y)
        let result = SIMD2(Float(x * scale), Float(y * scale))
        guard result.x.isFinite, result.y.isFinite, result != .zero else { return nil }
        return result
    }

    /// 将已经完成源运算的点提升到Double，不重新求法线或改变原点。
    static func scene(_ point: SIMD2<Float>) -> ScenePoint { ScenePoint(x: Double(point.x), y: Double(point.y)) }
}

/// 一条临时描边边界的线或rational conic；起点由前一段终点给出，便于修改末端miter。
struct StrokeBoundarySegment {
    /// nil为直线；非nil为圆弧或曲线偏移二次段的Float控制点。
    let control: SIMD2<Float>?
    /// conic正权重，普通二次段固定为1；直线的值不参与运算。
    let weight: Float
    /// 可被源码setLastPt替换的末点。
    var end: SIMD2<Float>
}

/// 单次同步后台描边的一条可编辑边界；只保留线和源Float conic，不跨隔离域共享。
final class StrokeLineBoundary {
    /// 第一条边尚未写入时为nil，其他时候是路径Move点。
    private(set) var start: SIMD2<Float>?
    /// 尚未转换的有序线段/圆弧，所有增长都先扣共享预算。
    private var segments: [StrokeBoundarySegment] = []
    /// 末点可用于接角、端帽及反向拼接；空路径返回nil。
    var last: SIMD2<Float>? { segments.last?.end ?? start }

    /// 开始一条边界；调用方每轮廓使用独立对象，不允许覆盖已有路径。
    func move(to point: SIMD2<Float>, output: StrokePathOutput) throws {
        try check(point, output: output)
        guard start == nil else { throw PAGError.renderingFailure("strokeBoundarySequence") }
        try output.budget.reserve(stride: 32)
        start = point
    }

    /// 追加一条线或正权重conic，临时点同样受幅度、数量、工作和字节政策限制。
    func append(to point: SIMD2<Float>, control: SIMD2<Float>? = nil, weight: Float = 1,
                output: StrokePathOutput) throws {
        guard start != nil else { throw PAGError.renderingFailure("strokeBoundarySequence") }
        guard segments.count < output.limits.maximumOutputElements else {
            throw PAGError.resourceLimitExceeded("maximumStrokeOutputElements")
        }
        try check(point, output: output)
        if let control { try check(control, output: output) }
        guard weight.isFinite, weight > 0 else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        try output.budget.reserve(stride: 64)
        segments.append(StrokeBoundarySegment(control: control, weight: weight, end: point))
    }

    /// 源miter/square覆盖上条Line终点；不会偷偷附加接角边，也允许更新仅有Move的路径。
    func replaceLast(with point: SIMD2<Float>, output: StrokePathOutput) throws {
        try check(point, output: output)
        guard start != nil else { throw PAGError.renderingFailure("strokeBoundarySequence") }
        if segments.isEmpty { start = point }
        else { segments[segments.count - 1].end = point }
    }

    /// 仿reversePathTo忽略对方最后一点，从当前端帽末端接上反向边；conic控制点无需改变。
    func appendReversed(_ other: StrokeLineBoundary, output: StrokePathOutput) throws {
        guard let first = other.start else { return }
        for index in other.segments.indices.reversed() {
            let segment = other.segments[index]
            let end = index == 0 ? first : other.segments[index - 1].end
            try append(to: end, control: segment.control, weight: segment.weight, output: output)
        }
    }

    /// 源Close检查所有存储点是否相同，包含圆弧控制点；面积或首末点相等不能替代。
    func isZeroLength(output: StrokePathOutput) throws -> Bool {
        guard let start else { return true }
        for segment in segments {
            try output.budget.consume()
            if segment.end != start || (segment.control != nil && segment.control != start) { return false }
        }
        return true
    }

    /// 完整边界输出为闭合路径，conic误差只相对实际Float曲线；反向用于统一复合outline绕序。
    func emit(reversed: Bool, restoration: SceneAffine, tolerance: Double, output: StrokePathOutput) throws {
        guard let start, let last else { return }
        var current = reversed ? last : start
        try output.append(.move, points: [StrokeLineMath.scene(current)])
        for offset in segments.indices {
            let index = reversed ? segments.count - 1 - offset : offset
            let segment = segments[index]
            let end = reversed ? (index == 0 ? start : segments[index - 1].end) : segment.end
            if let control = segment.control {
                try output.budget.reserve(stride: 512)
                let conic = StrokeConic(points: [StrokeLineMath.scene(current), StrokeLineMath.scene(control), StrokeLineMath.scene(end)],
                                        weights: [1, Double(segment.weight), 1])
                let curves = try StrokeConicApproximation.cubics(conic, tolerance: tolerance, transform: restoration, budget: &output.budget)
                for curve in curves { try output.append(.cubic, points: [curve.first, curve.second, curve.end]) }
            } else { try output.append(.line, points: [StrokeLineMath.scene(end)]) }
            current = end
        }
        try output.append(.close)
    }

    /// 临时路径与最终输出使用同一幅度政策，非有限几何不进入数组。
    private func check(_ point: SIMD2<Float>, output: StrokePathOutput) throws {
        try output.budget.consume()
        try output.limits.check(StrokeLineMath.scene(point))
    }
}
