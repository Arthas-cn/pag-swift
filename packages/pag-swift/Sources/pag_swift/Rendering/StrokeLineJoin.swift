/// 固定PathKit的接角与圆弧生成；前后段类型控制miter边界编辑，所有控制点在Float完成。
enum StrokeLineJoin {
    /// 按序追加两边接角；NearlyLine不动任何边，Near180 miter不能先按转向交换内外。
    static func append(before: SIMD2<Float>, after: SIMD2<Float>, pivot: SIMD2<Float>, radius: Float,
                       join: SourceLineJoin, miterLimit: Float, outer: StrokeLineBoundary,
                       inner: StrokeLineBoundary, previousIsLine: Bool = true, currentIsLine: Bool = true,
                       output: StrokePathOutput) throws {
        try output.budget.consume()
        let dot = before.x * after.x + before.y * after.y
        // NearlyLine连内侧pivot也省略；保留前一端点让下一条Line直接延续。
        if join != .bevel, dot >= 0, abs(1 - dot) <= 1.0 / 4096 { return }
        if join == .miter, dot < 0, abs(1 + dot) <= 1.0 / 4096 {
            // 源goto DO_BLUNT发生在交换之前；不能复用普通bevel的转向选择。
            try outer.append(to: pivot + after * radius, output: output)
            try innerJoin(inner, pivot: pivot, normal: after * radius, output: output)
            return
        }
        let clockwise = before.x * after.y > before.y * after.x
        let outside = clockwise ? outer : inner, inside = clockwise ? inner : outer
        let before = clockwise ? before : -before, after = clockwise ? after : -after
        if join == .round {
            let count = try arc(before: before, after: after, clockwise: clockwise, pivot: pivot,
                                radius: radius, boundary: outside, output: output)
            // BuildUnitArc可能返回零，源码这时连内侧pivot也不追加。
            if count > 0 { try innerJoin(inside, pivot: pivot, normal: after * radius, output: output) }
            return
        }
        if join == .bevel {
            try outside.append(to: pivot + after * radius, output: output)
        } else {
            let inverse = 1 / miterLimit
            let half = ((1 + dot) * 0.5).squareRoot()
            var appendsAfter = !currentIsLine
            if dot == 0, inverse <= Float(0.707106781) {
                try miterPoint(pivot + (before + after) * radius, previousIsLine: previousIsLine, boundary: outside, output: output)
            } else if half < inverse {
                appendsAfter = true
            } else {
                var mid = dot < 0 ? SIMD2(after.y - before.y, before.x - after.x) : before + after
                if dot < 0, clockwise == false { mid = -mid }
                guard let scaled = StrokeLineMath.scaled(mid, length: radius / half) else {
                    throw PAGError.resourceLimitExceeded("geometryPrecision")
                }
                // 只有前段Line能改末点；前段Cubic必须保留已算好的曲线终点再追加交点。
                try miterPoint(pivot + scaled, previousIsLine: previousIsLine, boundary: outside, output: output)
            }
            // 原始末verb为Cubic且没有自动闭合Line时，Close必须保留after角点，不能当成Line延伸。
            if appendsAfter { try outside.append(to: pivot + after * radius, output: output) }
        }
        try innerJoin(inside, pivot: pivot, normal: after * radius, output: output)
    }

    /// 源DO_MITER只在前段Line时覆盖末点；非线性段的控制多边形不得因接角变形。
    private static func miterPoint(_ point: SIMD2<Float>, previousIsLine: Bool,
                                   boundary: StrokeLineBoundary, output: StrokePathOutput) throws {
        if previousIsLine { try boundary.replaceLast(with: point, output: output) }
        else { try boundary.append(to: point, output: output) }
    }

    /// 内侧必须经过中心pivot，防止宽描边的短腿出现跨角斜线；不以相交计算替换此源规则。
    private static func innerJoin(_ boundary: StrokeLineBoundary, pivot: SIMD2<Float>, normal: SIMD2<Float>,
                                  output: StrokePathOutput) throws {
        try boundary.append(to: pivot, output: output)
        try boundary.append(to: pivot - normal, output: output)
    }

    /// 源BuildUnitArc逐象限生成最多四段conic，返回实际追加数量；末点可能故意停在象限边界。
    static func arc(before: SIMD2<Float>, after: SIMD2<Float>, clockwise: Bool, pivot: SIMD2<Float>,
                    radius: Float, boundary: StrokeLineBoundary, output: StrokePathOutput) throws -> Int {
        let x = before.x * after.x + before.y * after.y
        var y = before.x * after.y - before.y * after.x
        if abs(y) <= 1.0 / 4096, x > 0, clockwise ? y >= 0 : y <= 0 { return 0 }
        if clockwise == false { y = -y }
        let quadrant: Int
        if y == 0 { quadrant = 2 }
        else if x == 0 { quadrant = y > 0 ? 1 : 3 }
        else { quadrant = (y < 0 ? 2 : 0) + ((x < 0) != (y < 0) ? 1 : 0) }
        try output.budget.reserve(9, stride: 16)
        let points: [SIMD2<Float>] = [SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1), SIMD2(-1, 1),
                                     SIMD2(-1, 0), SIMD2(-1, -1), SIMD2(0, -1), SIMD2(1, -1), SIMD2(1, 0)]
        // 先组合Float旋转/反射与半径矩阵，再映射点；与先转点再乘半径会有不同舍入。
        let a = radius * before.x, b = radius * before.y
        let c = radius * (clockwise ? -before.y : before.y)
        let d = radius * (clockwise ? before.x : -before.x)
        for index in 0..<quadrant {
            try boundary.append(to: mapped(points[index * 2 + 2], a: a, b: b, c: c, d: d, pivot: pivot),
                control: mapped(points[index * 2 + 1], a: a, b: b, c: c, d: d, pivot: pivot),
                weight: Float(0.707106781), output: output)
        }
        let last = points[quadrant * 2], final = SIMD2(x, y)
        let dot = last.x * x + last.y * y
        if dot < 1 {
            let weight = ((1 + dot) * 0.5).squareRoot()
            guard let control = StrokeLineMath.scaled(last + final, length: 1 / weight) else {
                throw PAGError.resourceLimitExceeded("geometryPrecision")
            }
            // 无参EqualsWithinTolerance对有限点等同精确相等；不能在这里另设小角度epsilon。
            if control != last {
                try boundary.append(to: mapped(final, a: a, b: b, c: c, d: d, pivot: pivot),
                    control: mapped(control, a: a, b: b, c: c, d: d, pivot: pivot), weight: weight, output: output)
                return quadrant + 1
            }
        }
        return quadrant
    }

    /// 源仿射矩阵点映射次序，保留独立Float乘法与加法的舍入。
    private static func mapped(_ point: SIMD2<Float>, a: Float, b: Float, c: Float, d: Float,
                               pivot: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(a * point.x + c * point.y + pivot.x, b * point.x + d * point.y + pivot.y)
    }
}
