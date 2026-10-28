/// 完整纯Move/Line/Close路径的Swift描边入口；含任意曲线时由调用方整体留给混合后端。
enum StrokeLineOutline {
    /// 已接纳且非hairline的路径逐轮廓消费；所有临时边界和最终转换共享输出预算。
    static func append(_ path: StrokePath, admission: StrokeAdmission, style: StrokeStyle,
                       restoration: SceneAffine, tolerance: Double, to output: StrokePathOutput) throws {
        let radius = Float(style.width) * 0.5
        let miter = Float(style.miterLimit)
        let join: SourceLineJoin = style.join == .miter && miter <= 1 ? .bevel : style.join
        for contour in admission.subpaths {
            try output.budget.consume()
            guard contour.hasSegments else { continue }
            try output.budget.reserve(stride: 256)
            let first = try StrokeLineMath.point(path.points[contour.points.lowerBound])
            var lastRaw = first
            var lastNonzero = -1
            // 原迭代边决定前瞻，接受点只用于描边；记录最后有效边使逐段前瞻为O(1)。
            for index in (contour.points.lowerBound + 1)..<contour.points.upperBound {
                try output.budget.consume()
                let point = try StrokeLineMath.point(path.points[index])
                if point != lastRaw { lastNonzero = index }
                lastRaw = point
            }
            let addsClosingLine = contour.isClosed && lastRaw != first
            if addsClosingLine { lastNonzero = contour.points.upperBound }
            let state = StrokeContour(first: first, radius: radius, cap: style.cap, join: join, miter: miter)
            for index in (contour.points.lowerBound + 1)..<contour.points.upperBound {
                try state.line(to: StrokeLineMath.point(path.points[index]), hasFutureTangent: index < lastNonzero, output: output)
            }
            if addsClosingLine { try state.line(to: first, hasFutureTangent: false, output: output) }
            var closes = contour.isClosed
            if closes, style.cap != .butt {
                if state.segmentCount == 0 {
                    // Move+Close和全部被跳过的短段必须注入无前瞻零Line，并留给开放端帽收尾。
                    try state.line(to: first, hasFutureTangent: false, output: output)
                    closes = false
                } else if try state.outer.isZeroLength(output: output), try state.inner.isZeroLength(output: output) {
                    closes = false
                }
            }
            // Iter吞掉最后单独Move；其余Move使上一轮廓的末端cap走非Line入口。
            let endIsLine = closes || contour.verbs.upperBound >= path.verbs.count - 1
            try state.finish(closed: closes, endIsLine: endIsLine, restoration: restoration,
                             tolerance: tolerance, output: output)
        }
    }
}
