import Foundation

/// 一次字形映射的路径位置和单位切线；坐标仍属于文字图层，不含外层实例矩阵。
struct TextPathSample: Sendable {
    /// 路径上的位置，开放路径越界时可沿端点切线延长。
    let position: ScenePoint
    /// 指向当前路径正向的单位向量，退化到零时明确失败。
    let tangent: ScenePoint
}

/// 复用既有有界原生曲线度量，为文字路径提供首轮廓长度、反向和端点延长。
struct TextPathGeometry: Sendable {
    /// 首条非零长度轮廓的测量表；其它轮廓不参与上游PathMeasure取点。
    let measure: StrokeDashMeasure
    /// 当前选中轮廓的正向长度，单位为文字图层坐标。
    var length: Float { measure.length }
    /// 是否沿轮廓闭合接缝取余；开放端点则外推。
    var isClosed: Bool { measure.isClosed }

    /// 从已采样mask路径构造可测首轮廓；反向在度量前处理，空曲线明确失败。
    init(path: SourcePath, reversed: Bool, budget: inout GeometryBudget) throws {
        var stroke = try TrimPathConversion.make(.path(path, matrix: .identity), budget: &budget)
        if reversed { stroke = try TrimPathReversal.reversed(stroke, budget: &budget) }
        guard let value = try TrimPathMeasurement.first(in: stroke, budget: &budget), value.length > 0 else {
            throw PAGError.unsupportedFeature("textPathEmpty")
        }
        measure = value
    }

    /// 以当前曲线长度查询位置和方向；闭合取余，开放路径在首末切线外推。
    func sample(at distance: Double, budget: inout GeometryBudget) throws -> TextPathSample {
        try budget.consume()
        guard distance.isFinite, Float(distance).isFinite else {
            throw PAGError.resourceLimitExceeded("textPathDistance")
        }
        let length = Double(measure.length)
        var mapped = distance
        if measure.isClosed, distance < 0 || distance > length {
            mapped = distance.truncatingRemainder(dividingBy: length)
            if mapped < 0 { mapped += length }
        }
        let clamped = min(max(mapped, 0), length)
        let position = try measure.position(at: Float(clamped), budget: &budget)
        let curve = measure.curves[position.curve]
        let base = try curve.point(at: position.parameter, budget: &budget)
        let direction = try tangent(of: curve, at: position.parameter, budget: &budget)
        let excess = mapped - clamped
        guard (base.x + direction.x * excess).isFinite,
              (base.y + direction.y * excess).isFinite else {
            throw PAGError.resourceLimitExceeded("textPathDistance")
        }
        return TextPathSample(position: ScenePoint(x: base.x + direction.x * excess,
                                                    y: base.y + direction.y * excess),
                              tangent: direction)
    }

    /// PathMeasure的切线取值以本曲线近邻点估算；零导数时扩大采样，不能伪造水平切线。
    private func tangent(of curve: StrokeDashCurve, at parameter: Float,
                         budget: inout GeometryBudget) throws -> ScenePoint {
        for step: Float in [0.0001, 0.01, 1] {
            try budget.consume()
            let first = max(0, parameter - step)
            let last = min(1, parameter + step)
            let a = try curve.point(at: first, budget: &budget)
            let b = try curve.point(at: last, budget: &budget)
            let x = b.x - a.x, y = b.y - a.y
            let magnitude = hypot(x, y)
            if magnitude.isFinite, magnitude > 0 {
                return ScenePoint(x: x / magnitude, y: y / magnitude)
            }
        }
        throw PAGError.unsupportedFeature("textPathTangent")
    }
}
