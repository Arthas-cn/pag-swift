/// Trim的首个可测轮廓与距离提取适配；共享测量记录，不复用Stroke的Double切片。
enum TrimPathMeasurement {
    /// 按原路径轮廓顺序跳过无长度项，首个非空测量表即返回；预算或数值错误不能当作零长度跳过。
    static func first(in path: StrokePath, budget: inout GeometryBudget) throws -> StrokeDashMeasure? {
        for contour in try CurveContourIndex.ranges(in: path, budget: &budget) {
            if let measure = try StrokeDashMeasure.make(path, contour: contour, budget: &budget) { return measure }
        }
        return nil
    }

    /// 追加一段距离区间，成功各起Move且不Close；无交集返回false，数值/预算/取消抛出而非成功空片段。
    static func append(_ measure: StrokeDashMeasure, from lower: Float, to upper: Float,
                       to writer: inout TrimPathWriter) throws -> Bool {
        try writer.budget.consume()
        guard lower.isFinite, upper.isFinite else { throw PAGError.renderingFailure("trimPrecision") }
        // 源getSegment只处理负start和超长stop；两端对称clamp会把完全不相交的范围错误变成零Line。
        let lower = lower < 0 ? 0 : lower, upper = upper > measure.length ? measure.length : upper
        guard lower <= upper else { return false }
        let first = try measure.position(at: lower, budget: &writer.budget)
        let last = try measure.position(at: upper, budget: &writer.budget)
        let start = try TrimCurveExtraction.point(on: measure.curves[first.curve], at: first.parameter, budget: &writer.budget)
        try writer.append(.move, points: [start])
        if first.curve == last.curve {
            try TrimCurveExtraction.append(measure.curves[first.curve], from: first.parameter, to: last.parameter, to: &writer)
        } else {
            for index in first.curve..<last.curve {
                try TrimCurveExtraction.append(measure.curves[index], from: index == first.curve ? first.parameter : 0,
                                                to: 1, to: &writer)
            }
            try TrimCurveExtraction.append(measure.curves[last.curve], from: 0, to: last.parameter, to: &writer)
        }
        return true
    }
}
