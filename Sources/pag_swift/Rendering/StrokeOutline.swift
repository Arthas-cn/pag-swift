/// 已完成dash的临时中心线到复合描边outline；保留三类曲线的源语义，不调用系统描边。
enum StrokeOutline {
    /// 输入style.dashes必须nil；接纳后按hairline/矩形/Line/混合曲线分流，结果供nonzero填充。
    static func make(_ path: StrokePath, style: StrokeStyle, restoration: SceneAffine = .identity,
                     tolerance: Double, limits: StrokeBackendLimits = .standard,
                     budget: inout GeometryBudget) throws -> SourcePath {
        guard style.dashes == nil else { throw PAGError.invalidArgument("strokeRequiresDashedCenterline") }
        guard tolerance.isFinite, tolerance > 0 else { throw PAGError.invalidArgument("geometryTolerance") }
        let admission = try StrokeAdmission.inspect(path, style: style, limits: limits, budget: &budget)
        let output = try StrokePathOutput(budget: &budget, limits: limits)
        defer { budget = output.budget }
        if style.isHairline {
            // 上游hairline不扩张，中心线后续按fill消费；此处也不能为零段擅自补圆点。
            try StrokeFillPath.append(path, restoration: restoration, tolerance: tolerance, to: output)
            return try output.finish(restoring: restoration)
        }
        if let rectangle = try StrokeRectangle.detect(path, budget: &output.budget) {
            // 源整体矩形快路优先于任何短边规则，而且不受cap控制；不能交给CG自行选择语义。
            try rectangle.appendOutline(style: style, restoration: restoration, tolerance: tolerance, to: output)
            return try output.finish(restoring: restoration)
        }
        // 分流扫描也计入工作；标准输入最多16k条，在不可中断的contains前后都检查取消。
        try output.budget.consume(path.verbs.count)
        let hasCurve = path.verbs.contains {
            switch $0 {
            case .quad, .conic, .cubic: true
            case .move, .line, .close: false
            }
        }
        try Task.checkCancellation()
        if !hasCurve {
            // 整条纯Line路径共用源状态机，不能将混合曲线拆成互相独立的端帽。
            try StrokeLineOutline.append(path, admission: admission, style: style, restoration: restoration,
                                         tolerance: tolerance, to: output)
            return try output.finish(restoring: restoration)
        }
        return try StrokeCurveOutline.make(path, admission: admission, style: style, restoration: restoration,
                                           tolerance: tolerance, limits: limits, budget: &output.budget)
    }
}
