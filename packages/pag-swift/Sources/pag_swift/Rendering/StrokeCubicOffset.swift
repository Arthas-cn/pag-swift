/// 单侧、单个全局拐点区间的有界Cubic偏移；只追加到局部边界，失败由完整outline所有者丢弃。
enum StrokeCubicOffset {
    /// 已建立Move的边界追加Line/Quadratic；每侧每区间重新建立共享foundTangents状态。
    static func append(_ points: [SIMD2<Float>], radius: Float, side: Float,
                       start: Float, end: Float, to boundary: StrokeLineBoundary,
                       output: StrokePathOutput) throws {
        guard start.isFinite, end.isFinite, start >= 0, start < end, end <= 1 else {
            throw PAGError.invalidArgument("strokeCubicInterval")
        }
        let first = try StrokeCubicSampling.ray(points, at: start, radius: radius, side: side, budget: &output.budget)
        let last = try StrokeCubicSampling.ray(points, at: end, radius: radius, side: side, budget: &output.budget)
        let quad = StrokeOffsetQuad(start: start, end: end, first: first, last: last)
        var foundTangents = false
        try append(points, radius: radius, side: side, quad: quad, foundTangents: &foundTangents,
                   depth: 0, to: boundary, output: output)
    }

    /// 深度优先处理已采样节点；inout状态由整个区间共享，左子树改变后右兄弟立即可见。
    static func append(_ points: [SIMD2<Float>], radius: Float, side: Float, quad initial: StrokeOffsetQuad,
                       foundTangents: inout Bool, depth: Int, to boundary: StrokeLineBoundary,
                       output: StrokePathOutput) throws {
        try output.budget.consume()
        try output.budget.reserve(stride: 160)
        var quad = initial
        if !foundTangents {
            let result = try quad.intersection(needsControl: false, budget: &output.budget)
            if result == .quadratic { foundTangents = true }
            else if result == .degenerate || StrokeOffsetQuad.within(quad.first.offset, quad.last.offset, limit: 0.25) {
                let ray = try StrokeCubicSampling.ray(points, at: quad.middle, radius: radius, side: side, budget: &output.budget)
                if StrokeOffsetQuad.distanceSquared(ray.offset, from: quad.first.offset, to: quad.last.offset) < 0.0625 {
                    try boundary.append(to: quad.last.offset, output: output)
                    return
                }
            }
        }
        if foundTangents {
            let result = try quad.intersection(needsControl: true, budget: &output.budget)
            if result == .quadratic {
                let ray = try StrokeCubicSampling.ray(points, at: quad.middle, radius: radius, side: side, budget: &output.budget)
                if try quad.accepts(ray, budget: &output.budget) {
                    try boundary.append(to: quad.last.offset, control: quad.control, output: output)
                    return
                }
            } else if result == .degenerate, !quad.oppositeTangents {
                try boundary.append(to: quad.last.offset, output: output)
                return
            }
        }
        guard quad.last.offset.x.isFinite, quad.last.offset.y.isFinite else {
            throw PAGError.resourceLimitExceeded("geometryPrecision")
        }
        // 接受叶节点先于深度判断；确需细分才限深，并且先于Float中点停滞回退。
        guard depth < min(foundTangents ? 24 : 15, output.budget.maximumDepth) else {
            throw PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")
        }
        let middle = quad.middle
        let leftMiddle = (quad.start + middle) * 0.5
        guard quad.start < leftMiddle, leftMiddle < middle else {
            try boundary.append(to: quad.last.offset, output: output)
            return
        }
        let leftEnd = try StrokeCubicSampling.ray(points, at: middle, radius: radius, side: side, budget: &output.budget)
        let left = StrokeOffsetQuad(start: quad.start, end: middle, first: quad.first, last: leftEnd)
        try append(points, radius: radius, side: side, quad: left, foundTangents: &foundTangents,
                   depth: depth + 1, to: boundary, output: output)
        let rightMiddle = (middle + quad.end) * 0.5
        guard middle < rightMiddle, rightMiddle < quad.end else {
            // 左半已成功时只补父终点，不回滚左半；失败抛出时则由外层丢弃完整候选。
            try boundary.append(to: quad.last.offset, output: output)
            return
        }
        let rightStart = try StrokeCubicSampling.ray(points, at: middle, radius: radius, side: side, budget: &output.budget)
        let right = StrokeOffsetQuad(start: middle, end: quad.end, first: rightStart, last: quad.last)
        try append(points, radius: radius, side: side, quad: right, foundTangents: &foundTangents,
                   depth: depth + 1, to: boundary, output: output)
    }
}
