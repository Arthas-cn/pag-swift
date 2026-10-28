/// 已识别整体矩形的专门描边输出；源Float几何先确定，再以Double conic进入共用矢量管线。
extension StrokeRectangle {
    /// 忽略cap，按源miter门槛与严格孔洞条件生成完整outline；预算/取消或不可表示数值时失败。
    func appendOutline(style: StrokeStyle, restoration: SceneAffine, tolerance: Double, to output: StrokePathOutput) throws {
        try output.budget.consume()
        let width = Float(style.width), radius = width * 0.5
        let spanX = right - left, spanY = bottom - top
        let outer = StrokeRectangle(left: left - radius, top: top - radius, right: right + radius, bottom: bottom + radius)
        guard [width, radius, spanX, spanY, outer.left, outer.top, outer.right, outer.bottom].allSatisfy(\.isFinite) else {
            throw PAGError.resourceLimitExceeded("geometryPrecision")
        }
        let join: SourceLineJoin = style.join == .miter && Float(style.miterLimit) < Float(2).squareRoot() ? .bevel : style.join
        switch join {
        case .miter: try outer.appendRectangle(reversed: false, to: output)
        case .bevel:
            try output.budget.reserve(8, stride: 32)
            try polygon([point(left, outer.top), point(outer.left, top), point(outer.left, bottom), point(left, outer.bottom),
                         point(right, outer.bottom), point(outer.right, bottom), point(outer.right, top), point(right, outer.top)], to: output)
        case .round:
            try outer.appendRounded(radius: radius, restoration: restoration, tolerance: tolerance, to: output)
        }
        // 宽度等于任一边长时孔洞已经消失；不能沿用通用offset交叉后再用nonzero碰巧抵消。
        if width < min(spanX, spanY) {
            let inner = StrokeRectangle(left: left + radius, top: top + radius, right: right - radius, bottom: bottom - radius)
            try inner.appendRectangle(reversed: true, to: output)
        }
    }

    /// 固定外轮廓负绕序、孔洞正绕序；只统一本分支整个复合路径的方向，不分别翻转孔洞。
    private func appendRectangle(reversed: Bool, to output: StrokePathOutput) throws {
        try output.budget.reserve(4, stride: 32)
        let points = reversed ? [point(left, top), point(right, top), point(right, bottom), point(left, bottom)]
                              : [point(left, top), point(left, bottom), point(right, bottom), point(right, top)]
        try polygon(points, to: output)
    }

    /// 复现SkRRect.setRectXY的半径收紧和oval分支，圆角端点保留Float计算次序。
    private func appendRounded(radius: Float, restoration: SceneAffine, tolerance: Double, to output: StrokePathOutput) throws {
        let width = right - left, height = bottom - top
        guard width.isFinite, height.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        var radius = radius
        if width < radius + radius || height < radius + radius {
            radius *= min(width / (radius + radius), height / (radius + radius))
        }
        if radius <= 0 {
            try appendRectangle(reversed: false, to: output)
            return
        }
        try output.budget.reserve(12, stride: 32)
        let corners = [point(left, top), point(right, top), point(right, bottom), point(left, bottom)]
        if radius >= width * 0.5, radius >= height * 0.5 {
            // oval用两条边各半再相加，不能改为left+radius或先求和后除二。
            let x = left * 0.5 + right * 0.5, y = top * 0.5 + bottom * 0.5
            let points = [point(x, top), point(right, y), point(x, bottom), point(left, y)]
            try output.append(.move, points: [points[1]])
            var current = 1
            for _ in 0..<4 {
                let next = (current + 3) % 4
                try conic(from: points[current], through: corners[current], to: points[next],
                          restoration: restoration, tolerance: tolerance, output: output)
                current = next
            }
        } else {
            let points = [point(left + radius, top), point(right - radius, top), point(right, top + radius),
                          point(right, bottom - radius), point(right - radius, bottom), point(left + radius, bottom),
                          point(left, bottom - radius), point(left, top + radius)]
            try output.append(.move, points: [points[2]])
            var current = 2
            for (index, corner) in [1, 0, 3, 2].enumerated() {
                let next = (current + 7) % 8
                try conic(from: points[current], through: corners[corner], to: points[next],
                          restoration: restoration, tolerance: tolerance, output: output)
                current = next
                // 源startsWithConic只写三条直边，第四条由最终Close补齐，不能再追加重复Line。
                if index < 3 {
                    current = (current + 7) % 8
                    try output.append(.line, points: [points[current]])
                }
            }
        }
        try output.append(.close)
    }

    /// 将源四分之一圆conic转换为有界Double cubic，每次增长经过共用输出计费。
    private func conic(from start: ScenePoint, through control: ScenePoint, to end: ScenePoint,
                       restoration: SceneAffine, tolerance: Double, output: StrokePathOutput) throws {
        try output.budget.reserve(stride: 512)
        let conic = StrokeConic(points: [start, control, end], weights: [1, Double(Float(0.707106781)), 1])
        let curves = try StrokeConicApproximation.cubics(conic, tolerance: tolerance, transform: restoration, budget: &output.budget)
        for curve in curves { try output.append(.cubic, points: [curve.first, curve.second, curve.end]) }
    }

    /// 写入已确定绕序的闭合多边形，保留源退化边，不在这里做面积过滤。
    private func polygon(_ points: [ScenePoint], to output: StrokePathOutput) throws {
        try output.append(.move, points: [points[0]])
        for point in points.dropFirst() { try output.append(.line, points: [point]) }
        try output.append(.close)
    }

    /// 只提升已经完成Float运算的坐标；实际坐标与element限额由输出器检查。
    private func point(_ x: Float, _ y: Float) -> ScenePoint { ScenePoint(x: Double(x), y: Double(y)) }
}
