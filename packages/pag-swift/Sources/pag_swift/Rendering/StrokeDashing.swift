/// 固定PathKit虚线状态机的Swift适配；输出保留精确零on与闭合缝，完全不调用CG dash。
enum StrokeDashing {
    /// 输入必须已由StrokeCenterline规范化并处理全路径零Line；预算、取消或实际输出超限明确失败。
    static func make(_ path: StrokePath, style: StrokeStyle, limits: StrokeBackendLimits = .standard,
                     budget: inout GeometryBudget) throws -> StrokePath {
        let admission = try StrokeAdmission.inspect(path, style: style, limits: limits, budget: &budget)
        guard let pattern = style.dashes else { return path }
        let output = try StrokeDashOutput(budget: &budget, limits: limits)
        defer { budget = output.budget }
        let initial = firstInterval(pattern)
        var pieces = 0
        for contour in admission.subpaths {
            guard let measure = try StrokeDashMeasure.make(path, contour: contour, budget: &output.budget) else { continue }
            var distance: Double = 0
            var remaining = Double(initial.length)
            var index = initial.index
            var skipFirst = measure.isClosed
            var added = false
            var cycleDistance: Double = 0
            var cycleSteps = 0
            while distance < Double(measure.length) {
                try output.budget.consume()
                added = false
                if index.isMultiple(of: 2), skipFirst == false {
                    try append(measure, from: Float(distance), to: Float(distance + remaining),
                               startsNewContour: true, pieces: &pieces, output: output)
                    added = true
                }
                distance += remaining
                skipFirst = false
                index = (index + 1) % pattern.intervals.count
                remaining = pattern.intervals[index]
                cycleSteps += 1
                if cycleSteps == pattern.intervals.count {
                    // 单个零项必须前进索引；只有整周期都无法推进Double距离时才停止，不能塞入epsilon。
                    guard distance > cycleDistance else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
                    cycleDistance = distance
                    cycleSteps = 0
                }
            }
            if measure.isClosed, initial.index.isMultiple(of: 2) {
                try append(measure, from: 0, to: initial.length, startsNewContour: added == false,
                           pieces: &pieces, output: output)
            }
        }
        let result = try output.finish()
        let solid = StrokeStyle(width: style.width, cap: style.cap, join: style.join, miterLimit: style.miterLimit, dashes: nil)
        // 真正outline输入是dash之后的路径；不能拿较大的输出限额替换16k/49k/4k输入接纳。
        _ = try StrokeAdmission.inspect(result, style: solid, limits: limits, budget: &output.budget)
        return result
    }

    /// phase已按Float周期规范化；恰到正间隔右端进入下一项，零间隔在phase为零时仍可选中。
    private static func firstInterval(_ pattern: StrokeDashPattern) -> (index: Int, length: Float) {
        var phase = Float(pattern.phase)
        for (index, value) in pattern.intervals.enumerated() {
            let gap = Float(value)
            if phase > gap || (phase == gap && gap != 0) { phase -= gap }
            else { return (index, gap - phase) }
        }
        // Float逐项减法与period求和可能不一致；固定源码在这条分支回到首间隔。
        return (0, Float(pattern.intervals[0]))
    }

    /// 实际on次数单独受限，包含零on及最后闭合缝补段；预估长度不能替代这项计费。
    private static func append(_ measure: StrokeDashMeasure, from start: Float, to end: Float, startsNewContour: Bool,
                               pieces: inout Int, output: StrokeDashOutput) throws {
        guard pieces < output.limits.maximumDashPieces else { throw PAGError.resourceLimitExceeded("maximumStrokeDashPieces") }
        pieces += 1
        try measure.append(from: start, to: end, startsNewContour: startsNewContour, to: output)
    }
}
