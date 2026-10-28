/// 在完整局部候选中消费Line/Quad/Conic/Cubic，所有轮廓成功才发布，不存在系统描边回退。
enum StrokeCurveOutline {
    /// 返回完整恢复后的outline；预算/取消/精度错误使整次候选失败，已消耗预算不回退。
    static func make(_ path: StrokePath, admission: StrokeAdmission, style: StrokeStyle,
                     restoration: SceneAffine, tolerance: Double, limits: StrokeBackendLimits,
                     budget: inout GeometryBudget) throws -> SourcePath {
        let output = try StrokePathOutput(budget: &budget, limits: limits)
        defer { budget = output.budget }
        let miter = Float(style.miterLimit)
        let join: SourceLineJoin = style.join == .miter && miter <= 1 ? .bevel : style.join
        for contour in admission.subpaths {
            try output.budget.consume()
            guard contour.hasSegments else { continue }
            try output.budget.reserve(stride: 256)
            let first = try StrokeLineMath.point(path.points[contour.points.lowerBound])
            let scan = try lastTangent(path, contour: contour, first: first, budget: &output.budget)
            let state = StrokeContour(first: first, radius: Float(style.width) * 0.5, cap: style.cap, join: join, miter: miter)
            var pointIndex = contour.points.lowerBound + 1
            var lastIsLine = false
            for verbIndex in (contour.verbs.lowerBound + 1)..<contour.verbs.upperBound {
                let verb = path.verbs[verbIndex]
                try output.budget.consume(1 + verb.pointCount)
                switch verb {
                case .line:
                    try state.line(to: StrokeLineMath.point(path.points[pointIndex]), hasFutureTangent: verbIndex < scan.last, output: output)
                    lastIsLine = true
                case .quad:
                    try state.quad(control: StrokeLineMath.point(path.points[pointIndex]),
                                   end: StrokeLineMath.point(path.points[pointIndex + 1]), output: output)
                    lastIsLine = false
                case .conic(let weight):
                    try state.conic(control: StrokeLineMath.point(path.points[pointIndex]),
                                    end: StrokeLineMath.point(path.points[pointIndex + 1]), weight: weight, output: output)
                    lastIsLine = false
                case .cubic:
                    try state.cubic(first: StrokeLineMath.point(path.points[pointIndex]),
                        second: StrokeLineMath.point(path.points[pointIndex + 1]), end: StrokeLineMath.point(path.points[pointIndex + 2]), output: output)
                    // 外层记录原verb，不能被内部lineTo的数量或是否实际接纳覆盖。
                    lastIsLine = false
                case .close:
                    if scan.closingLine {
                        try state.line(to: first, hasFutureTangent: false, output: output)
                        lastIsLine = true
                    }
                case .move: throw PAGError.invalidArgument("unnormalizedStrokePath")
                }
                pointIndex += verb.pointCount
            }
            var closes = contour.isClosed
            if closes, style.cap != .butt {
                if state.segmentCount == 0 {
                    try state.line(to: first, hasFutureTangent: false, output: output)
                    closes = false
                    lastIsLine = true
                } else if try state.outer.isZeroLength(output: output), try state.inner.isZeroLength(output: output) {
                    closes = false
                    lastIsLine = true
                }
            }
            // 真Close使用lastSegment；开放收尾仅在Done或末尾单Move时沿用它，其他Move传false。
            let endIsLine = lastIsLine && (closes || contour.verbs.upperBound >= path.verbs.count - 1)
            try state.finish(closed: closes, endIsLine: endIsLine, restoration: restoration, tolerance: tolerance, output: output)
        }
        return try output.finish(restoring: restoration)
    }

    /// 一次扫描原始指令找到最后非零切向；任一曲线控制点或终点不同即有效，不使用描边接受点。
    private static func lastTangent(_ path: StrokePath, contour: StrokeSubpath, first: SIMD2<Float>,
                                     budget: inout GeometryBudget) throws -> (last: Int, closingLine: Bool) {
        var previous = first, last = -1, pointIndex = contour.points.lowerBound + 1
        var closingLine = false
        for verbIndex in (contour.verbs.lowerBound + 1)..<contour.verbs.upperBound {
            let verb = path.verbs[verbIndex]
            try budget.consume(1 + verb.pointCount)
            if verb == .close {
                closingLine = previous != first
                if closingLine { last = verbIndex }
            } else {
                var nonzero = false
                for index in pointIndex..<(pointIndex + verb.pointCount) {
                    if try StrokeLineMath.point(path.points[index]) != previous { nonzero = true }
                }
                if nonzero { last = verbIndex }
                previous = try StrokeLineMath.point(path.points[pointIndex + verb.pointCount - 1])
            }
            pointIndex += verb.pointCount
        }
        return (last, closingLine)
    }
}
