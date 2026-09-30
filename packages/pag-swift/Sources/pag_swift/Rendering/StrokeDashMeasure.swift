/// 一条子路径的Float测量表和Double提取曲线；不含系统对象，也不把测量误差称为严格弧长界。
struct StrokeDashMeasure: Sendable {
    /// 按源顺序保留的可测曲线；compact规则可能替换其起点。
    let curves: [StrokeDashCurve]
    /// 累计距离严格递增的记录，同一曲线可有多个测量叶段。
    let records: [StrokeDashRecord]
    /// Float累计总长度，严格为正；查询端点钳制到此值。
    let length: Float
    /// 原输入的Close状态，只用于dash接缝，不复制到输出指令。
    let isClosed: Bool

    /// 输入必须先通过StrokeAdmission；无测量记录返回nil，工作/内存/深度不足或取消抛出。
    static func make(_ path: StrokePath, contour: StrokeSubpath, budget: inout GeometryBudget) throws -> Self? {
        try budget.consume()
        try budget.reserve(stride: 128)
        var builder = StrokeDashMeasureBuilder()
        let first = path.points[contour.points.lowerBound]
        var current = first
        var index = contour.points.lowerBound + 1
        for verb in path.verbs[contour.verbs].dropFirst() {
            try budget.consume(1 + verb.pointCount)
            let curve: StrokeDashCurve
            switch verb {
            case .line: curve = .line(start: current, end: path.points[index])
            case .quad:
                curve = .quad(start: current, control: path.points[index], end: path.points[index + 1])
            case .conic(let weight):
                curve = .conic(start: current, control: path.points[index], end: path.points[index + 1], weight: weight)
            case .cubic:
                curve = .cubic(start: current, first: path.points[index], second: path.points[index + 1], end: path.points[index + 2])
            case .close: continue
            case .move: throw PAGError.invalidArgument("unnormalizedStrokePath")
            }
            // 测量始终用原段，只有输出曲线起点使用最后保留点；不能把被吞短段重新计长。
            try builder.append(curve, retainedStart: builder.curves.last?.end ?? first, budget: &budget)
            current = curve.end
            index += verb.pointCount
        }
        guard builder.metric.records.isEmpty == false else { return nil }
        if contour.isClosed, let last = builder.curves.last?.end {
            try builder.append(.line(start: last, end: first), retainedStart: last, budget: &budget)
        }
        try budget.reserve(stride: 128)
        return Self(curves: builder.curves, records: builder.metric.records, length: builder.metric.distance, isClosed: contour.isClosed)
    }

    /// 截取距离范围并保留源曲线拓扑；末段超长正常钳制，等长范围仍输出零Line。
    func append(from start: Float, to end: Float, startsNewContour: Bool, to output: StrokeDashOutput) throws {
        try output.budget.consume()
        // Swift min/max可能掩盖NaN；先保留源码!(start<=stop)对NaN的失败语义，再处理合法越界距离。
        guard start.isNaN == false, end.isNaN == false else { throw PAGError.invalidArgument("strokeDashRange") }
        let start = max(0, start), end = min(length, end)
        guard start.isFinite, end.isFinite, start <= end else { throw PAGError.invalidArgument("strokeDashRange") }
        let first = try position(at: start, budget: &output.budget)
        let last = try position(at: end, budget: &output.budget)
        if startsNewContour {
            let point = try curves[first.curve].point(at: first.parameter, budget: &output.budget)
            try output.append(.move, points: [point])
        }
        if first.curve == last.curve {
            try curves[first.curve].append(from: first.parameter, to: last.parameter, to: output)
        } else {
            for index in first.curve..<last.curve {
                try curves[index].append(from: index == first.curve ? first.parameter : 0, to: 1, to: output)
            }
            try curves[last.curve].append(from: 0, to: last.parameter, to: output)
        }
    }

    /// lower-bound使距离恰到边界时选择前曲线终点；插值按源码Float运算次序，不提前用Double除法。
    private func position(at distance: Float, budget: inout GeometryBudget) throws -> (curve: Int, parameter: Float) {
        var low = 0, high = records.count - 1
        while low < high {
            try budget.consume()
            let middle = low + (high - low) / 2
            if records[middle].distance < distance { low = middle + 1 }
            else { high = middle }
        }
        let record = records[low]
        let previousDistance: Float = low == 0 ? 0 : records[low - 1].distance
        let previousParameter: Float = low > 0 && records[low - 1].curve == record.curve ? records[low - 1].parameter : 0
        let parameter = previousParameter + (record.parameter - previousParameter) * (distance - previousDistance) / (record.distance - previousDistance)
        guard parameter.isFinite, parameter >= 0, parameter <= 1 else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        return (record.curve, parameter)
    }
}

/// 固定PathKit测量表的纯值记录，累计距离不增长的叶段不入表。
struct StrokeDashRecord: Sendable {
    /// 到本叶段结束处的Float累计距离，严格大于前一记录。
    let distance: Float
    /// 此叶段所属输出原曲线的数组下标。
    let curve: Int
    /// 整数参数经源Float倒数换算的结束参数，范围0...1。
    let parameter: Float
}

/// 单轮廓测量的局部可变构建器；Float影子仅用来决定测量分段，不回写Double输出曲线。
private struct StrokeDashMeasureBuilder {
    /// 已有至少一条测量记录的曲线；失败时随整个构建器丢弃。
    var curves: [StrokeDashCurve] = []
    /// 四种原曲线共用的Float测量状态；compact输出起点仅在测量增长之后替换。
    var metric = StrokeDashMetric()

    /// 先测量原曲线，只有累计增长才存compact输出曲线；存储失败由拥有者丢弃整个构建器。
    mutating func append(_ curve: StrokeDashCurve, retainedStart: ScenePoint, budget: inout GeometryBudget) throws {
        let previous = metric.distance
        switch curve {
        case let .line(start, end):
            try metric.appendLine(from: point(start), to: point(end), curveIndex: curves.count, budget: &budget)
        case let .quad(start, control, end):
            let original = try StrokeQuadCurve(start: point(start), control: point(control), end: point(end))
            try metric.append(original, curveIndex: curves.count, budget: &budget)
        case let .conic(start, control, end, weight):
            let original = try StrokeConicCurve(start: point(start), control: point(control), end: point(end), weight: weight)
            try metric.append(original, curveIndex: curves.count, budget: &budget)
        case let .cubic(start, first, second, end):
            try metric.appendCubic(from: point(start), firstControl: point(first), secondControl: point(second),
                                   to: point(end), curveIndex: curves.count, budget: &budget)
        }
        if metric.distance > previous {
            try budget.reserve(stride: 128)
            curves.append(curve.replacingStart(with: retainedStart))
        }
    }

    /// 只建立测量影子，原曲线控制点仍保留在Double枚举中。
    private func point(_ value: ScenePoint) -> SIMD2<Float> { SIMD2(Float(value.x), Float(value.y)) }
}
