/// Quad/Conic单侧偏移的共享有界递归；沿原参数采样，不使用Cubic的切线状态或停滞Line快路。
enum StrokeQuadraticOffset {
    /// 向已有Move的局部边界追加二次曲线偏移；区间必须严格非空，失败由完整候选拥有者丢弃。
    static func append(_ curve: StrokeQuadCurve, radius: Float, side: Float, start: Float = 0, end: Float = 1,
                       to boundary: StrokeLineBoundary, output: StrokePathOutput) throws {
        try append(start: start, end: end, to: boundary, output: output) { parameter, budget in
            try StrokeQuadraticSampling.ray(curve, at: parameter, radius: radius, side: side, budget: &budget)
        }
    }

    /// 向已有Move的局部边界追加原Conic偏移；不先chop成局部参数曲线，也不生成内部cusp圆。
    static func append(_ curve: StrokeConicCurve, radius: Float, side: Float, start: Float = 0, end: Float = 1,
                       to boundary: StrokeLineBoundary, output: StrokePathOutput) throws {
        try append(start: start, end: end, to: boundary, output: output) { parameter, budget in
            try StrokeQuadraticSampling.ray(curve, at: parameter, radius: radius, side: side, budget: &budget)
        }
    }

    /// 验证外部区间后进入无缓存根节点；同步非逃逸采样闭包只分派两种基础曲线公式。
    private static func append(start: Float, end: Float, to boundary: StrokeLineBoundary, output: StrokePathOutput,
                               ray: (Float, inout GeometryBudget) throws -> StrokeOffsetRay) throws {
        try output.budget.consume()
        guard start.isFinite, end.isFinite, start >= 0, start < end, end <= 1 else {
            throw PAGError.invalidArgument("strokeQuadraticInterval")
        }
        try append(start: start, end: end, first: nil, last: nil, depth: 0, to: boundary, output: output, ray: ray)
    }

    /// 每节点先恢复源初始化的cache语义，再比较候选；有限塌缩区间仍求值，持续Split最终由深度限制失败。
    private static func append(start: Float, end: Float, first cachedFirst: StrokeOffsetRay?, last cachedLast: StrokeOffsetRay?,
                               depth: Int, to boundary: StrokeLineBoundary, output: StrokePathOutput,
                               ray: (Float, inout GeometryBudget) throws -> StrokeOffsetRay) throws {
        try output.budget.consume()
        try output.budget.reserve(stride: 160)
        let middle = (start + end) * 0.5
        let canInherit = start < middle && middle < end
        // initWithStart/End失败已经清空两端cache；不能留下父ray，也不能提前补父终点Line。
        let first = try (canInherit ? cachedFirst : nil) ?? ray(start, &output.budget)
        let last = try (canInherit ? cachedLast : nil) ?? ray(end, &output.budget)
        var quad = StrokeOffsetQuad(start: start, end: end, first: first, last: last)
        switch try quad.intersection(needsControl: true, budget: &output.budget) {
        case .quadratic:
            let mid = try ray(middle, &output.budget)
            if try quad.accepts(mid, budget: &output.budget) {
                try boundary.append(to: last.offset, control: quad.control, output: output)
                return
            }
        case .degenerate:
            // 与Cubic不同，Quad/Conic即使oppositeTangents也无条件接受这条退化Line。
            try boundary.append(to: last.offset, output: output)
            return
        case .split: break
        }
        // 先接受叶才限深；保持通用预算最高32，比源Quad/Conic上限33更严格。
        guard depth < min(33, output.budget.maximumDepth) else {
            throw PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")
        }
        try append(start: start, end: middle, first: first, last: nil, depth: depth + 1,
                   to: boundary, output: output, ray: ray)
        // 右子在左子完整结束后才采样；它只可能继承父终ray，不能复用左子的全局中点采样。
        try append(start: middle, end: end, first: nil, last: last, depth: depth + 1,
                   to: boundary, output: output, ray: ray)
    }
}
