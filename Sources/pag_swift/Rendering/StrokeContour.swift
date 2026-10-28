/// 一条混合描边轮廓的接受点、法线和双边界；跳过短段不得更新任何几何状态。
final class StrokeContour {
    /// Move起点，用于闭合连接及起端帽，即使首条短段被跳过也不改变。
    let first: SIMD2<Float>
    /// 源Float半宽，当前入口已排除hairline。
    let radius: Float
    /// 开放轮廓端帽，Close仅在退化分支使用它。
    let cap: SourceLineCap
    /// 已完成miter<=1回落后的接角。
    let join: SourceLineJoin
    /// Float miter阈值，非miter时不参与运算。
    let miter: Float
    /// 沿源法线一侧的可变边界，不等同于所有转角处的几何外侧。
    let outer = StrokeLineBoundary()
    /// 相反一侧，最后反向接入开放轮廓或作为闭合孔洞。
    let inner = StrokeLineBoundary()
    /// 已接受段数；零段也计数并影响后续短边跳过。
    private(set) var segmentCount = 0
    /// 最近接受的中心点，不能由原迭代的短边终点覆盖。
    private var previous: SIMD2<Float>
    /// 首次接受段单位法线，默认零段为(1,0)。
    private var firstUnit = SIMD2<Float>.zero
    /// 首次接受段半宽法线，起端帽保留原Float乘法结果。
    private var firstNormal = SIMD2<Float>.zero
    /// 首次外侧Move点，最后起端帽以它为stop。
    private var firstOuter = SIMD2<Float>.zero
    /// 最近接受段单位法线，NearlyLine跳过join仍须更新它。
    private var previousUnit = SIMD2<Float>.zero
    /// 最近接受段半宽法线，用于末端帽。
    private var previousNormal = SIMD2<Float>.zero
    /// 最近成功preJoin的实际段类型；与driver的原始verb标记独立，短段跳过不修改。
    private var previousIsLine = false
    /// 当前轮廓的尖点圆；主体结束后并入同一复合填充，不能独立绘制造成alpha叠加。
    private var cusps: [StrokeLineBoundary] = []

    /// 建立单轮廓状态，不复制中心线数组或创建平台对象。
    init(first: SIMD2<Float>, radius: Float, cap: SourceLineCap, join: SourceLineJoin, miter: Float) {
        self.first = first
        previous = first
        self.radius = radius
        self.cap = cap
        self.join = join
        self.miter = miter
    }

    /// 按源lineTo接纳终点，后继切向只取原始迭代边；失败或取消不会发布部分outline。
    func line(to point: SIMD2<Float>, hasFutureTangent: Bool, using overrideJoin: SourceLineJoin? = nil,
              output: StrokePathOutput) throws {
        try output.budget.consume()
        let delta = point - previous
        let teeny = abs(delta.x) <= 1.0 / 16384 && abs(delta.y) <= 1.0 / 16384
        // 只有没有后继切向的首次非Butt短段可以保留；跳过不能推进previous或更新法线。
        if teeny && (cap == .butt || segmentCount > 0 || hasFutureTangent) { return }
        guard let normals = try begin(toward: point, isLine: true, join: overrideJoin ?? join, output: output) else { return }
        try outer.append(to: point + normals.normal, output: output)
        try inner.append(to: point - normals.normal, output: output)
        complete(at: point, normal: normals.normal, unit: normals.unit)
    }

    /// 以最后接受点构造普通二次曲线，按源分类处理降阶或完整两侧偏移，不借用Cubic状态机。
    func quad(control: SIMD2<Float>, end: SIMD2<Float>, output: StrokePathOutput) throws {
        try output.budget.reserve(stride: 128)
        let curve = try StrokeQuadCurve(start: previous, control: control, end: end)
        let reduction = try StrokeQuadraticAnalysis.reduction(of: curve, budget: &output.budget)
        try appendQuadratic(reduction, control: control, end: end, output: output) { side, boundary in
            try StrokeQuadraticOffset.append(curve, radius: radius, side: side, to: boundary, output: output)
        }
    }

    /// 有理二次保留权重和原Float公式；控制点入口与末法线规则和普通二次共享，失败不回退。
    func conic(control: SIMD2<Float>, end: SIMD2<Float>, weight: Float, output: StrokePathOutput) throws {
        try output.budget.reserve(stride: 128)
        let curve = try StrokeConicCurve(start: previous, control: control, end: end, weight: weight)
        let reduction = try StrokeQuadraticAnalysis.reduction(of: curve, budget: &output.budget)
        try appendQuadratic(reduction, control: control, end: end, output: output) { side, boundary in
            try StrokeQuadraticOffset.append(curve, radius: radius, side: side, to: boundary, output: output)
        }
    }

    /// 两类三点曲线共享接受状态；只有第二条回折边临时Round，真正曲线按原P2完成postJoin。
    private func appendQuadratic(_ reduction: StrokeQuadraticReduction, control: SIMD2<Float>, end: SIMD2<Float>,
                                 output: StrokePathOutput, append: (Float, StrokeLineBoundary) throws -> Void) throws {
        switch reduction {
        case .point, .line:
            try line(to: end, hasFutureTangent: false, output: output)
        case .reversal(let point):
            try line(to: point, hasFutureTangent: false, output: output)
            try line(to: end, hasFutureTangent: false, using: .round, output: output)
        case .curve:
            guard let normals = try begin(toward: control, isLine: false, join: join, output: output) else {
                // 源仅在preJoin失败时允许Line；任一偏移失败仍丢弃完整候选。
                try line(to: end, hasFutureTangent: false, output: output)
                return
            }
            try append(1, outer)
            try append(-1, inner)
            // setQuad/ConicEndNormal只看最后控制边；不能套用Cubic的跨控制点补救。
            if let tangent = StrokeLineMath.scaled(end - control, length: 1) {
                let unit = SIMD2(tangent.y, -tangent.x)
                complete(at: end, normal: unit * radius, unit: unit)
            } else { complete(at: end, normal: normals.normal, unit: normals.unit) }
        }
    }

    /// 以最后接受点分类Cubic；降阶无前瞻且内部暂Round，真正非线性按全局拐点追加两侧偏移。
    func cubic(first: SIMD2<Float>, second: SIMD2<Float>, end: SIMD2<Float>, output: StrokePathOutput) throws {
        try output.budget.reserve(4, stride: 16)
        let controls = [previous, first, second, end]
        let reduction = try StrokeCubicAnalysis.reduction(of: controls, budget: &output.budget)
        switch reduction {
        case .point, .line:
            try line(to: end, hasFutureTangent: false, output: output)
        case .polyline(let points):
            // 第一个保留点的入口接角仍由原style决定；只在后续内部连接启用Round。
            try line(to: points[0], hasFutureTangent: false, output: output)
            for point in points.dropFirst() { try line(to: point, hasFutureTangent: false, using: .round, output: output) }
            try line(to: end, hasFutureTangent: false, using: .round, output: output)
        case .curve(let tangent):
            guard let normals = try begin(toward: tangent, isLine: false, join: join, output: output) else {
                // 源preJoin失败才用无前瞻Line；已经开始偏移后的失败绝不进入这个回退。
                try line(to: end, hasFutureTangent: false, output: output)
                return
            }
            let inflections = try StrokeCubicSampling.inflections(controls, budget: &output.budget)
            var start: Float = 0
            for index in 0...inflections.count {
                let next: Float = index < inflections.count ? inflections[index] : 1
                try StrokeCubicOffset.append(controls, radius: radius, side: 1, start: start, end: next, to: outer, output: output)
                try StrokeCubicOffset.append(controls, radius: radius, side: -1, start: start, end: next, to: inner, output: output)
                start = next
            }
            if let parameter = try StrokeCubicSampling.cusp(controls, budget: &output.budget) {
                let center = try StrokeCubicAnalysis.position(controls, at: parameter)
                try output.budget.reserve(stride: 32)
                cusps.append(try StrokeCuspContour.make(center: center, radius: radius, output: output))
            }
            let ending = try endNormal(controls, initial: normals)
            // postJoin使用原P3；不能用Horner(1)或偏移ray反推中心点。
            complete(at: end, normal: ending.normal, unit: ending.unit)
        }
    }

    /// 用闭合接角或两个开放端帽完成复合轮廓，整个结果反向后与既有nonzero绕序统一。
    func finish(closed: Bool, endIsLine: Bool, restoration: SceneAffine, tolerance: Double,
                output: StrokePathOutput) throws {
        guard segmentCount > 0, let innerEnd = inner.last else { return }
        if closed {
            try StrokeLineJoin.append(before: previousUnit, after: firstUnit, pivot: previous, radius: radius,
                                      join: join, miterLimit: miter, outer: outer, inner: inner,
                                      previousIsLine: previousIsLine, currentIsLine: endIsLine, output: output)
            try outer.emit(reversed: true, restoration: restoration, tolerance: tolerance, output: output)
            try inner.emit(reversed: false, restoration: restoration, tolerance: tolerance, output: output)
        } else {
            try appendCap(pivot: previous, normal: previousNormal, stop: innerEnd, isLine: endIsLine, output: output)
            try outer.appendReversed(inner, output: output)
            // 源起帽刻意使用最后接受段的类型，并非首段类型或外层原始verb。
            try appendCap(pivot: first, normal: -firstNormal, stop: firstOuter, isLine: previousIsLine, output: output)
            try outer.emit(reversed: true, restoration: restoration, tolerance: tolerance, output: output)
        }
        for cusp in cusps {
            try cusp.emit(reversed: true, restoration: restoration, tolerance: tolerance, output: output)
        }
    }

    /// 源preJoin生成首法线并连接上一接受段；Butt零切线返回nil，其他零段用轴向默认法线。
    private func begin(toward point: SIMD2<Float>, isLine: Bool, join: SourceLineJoin,
                       output: StrokePathOutput) throws -> (normal: SIMD2<Float>, unit: SIMD2<Float>)? {
        try output.budget.consume()
        let unit: SIMD2<Float>
        if let tangent = StrokeLineMath.scaled(point - previous, length: 1) { unit = SIMD2(tangent.y, -tangent.x) }
        else {
            if cap == .butt { return nil }
            unit = SIMD2(1, 0)
        }
        let normal = unit * radius
        if segmentCount == 0 {
            firstUnit = unit
            firstNormal = normal
            firstOuter = previous + normal
            try outer.move(to: firstOuter, output: output)
            try inner.move(to: previous - normal, output: output)
        } else {
            try StrokeLineJoin.append(before: previousUnit, after: unit, pivot: previous, radius: radius,
                join: join, miterLimit: miter, outer: outer, inner: inner,
                previousIsLine: previousIsLine, currentIsLine: isLine, output: output)
        }
        previousIsLine = isLine
        return (normal, unit)
    }

    /// 源postJoin仅在本段完整完成后推进接受点与末法线，供短边和后继连接使用。
    private func complete(at point: SIMD2<Float>, normal: SIMD2<Float>, unit: SIMD2<Float>) {
        previous = point
        previousUnit = unit
        previousNormal = normal
        segmentCount += 1
    }

    /// 源setCubicEndNormal先修复首末退化控制边；必要时保留首法线，否则先单位化再Float乘半宽。
    private func endNormal(_ points: [SIMD2<Float>], initial: (normal: SIMD2<Float>, unit: SIMD2<Float>)) throws
        -> (normal: SIMD2<Float>, unit: SIMD2<Float>) {
        var first = points[1] - points[0], last = points[3] - points[2]
        if degenerate(first), degenerate(last) { return initial }
        if degenerate(first) { first = points[2] - points[0] }
        if degenerate(last) { last = points[3] - points[1] }
        if degenerate(first) || degenerate(last) { return initial }
        guard let tangent = StrokeLineMath.scaled(last, length: 1) else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        let unit = SIMD2(tangent.y, -tangent.x)
        return (unit * radius, unit)
    }

    /// 源CanNormalize只排除精确零和非有限向量；不得复用短Line的容差门槛。
    private func degenerate(_ vector: SIMD2<Float>) -> Bool {
        vector == .zero || !vector.x.isFinite || !vector.y.isFinite
    }

    /// 源Round为两段Float四分圆，Square按isLine选择改末点或补三条边，Butt只连接stop。
    private func appendCap(pivot: SIMD2<Float>, normal: SIMD2<Float>, stop: SIMD2<Float>,
                           isLine: Bool, output: StrokePathOutput) throws {
        let parallel = SIMD2(-normal.y, normal.x)
        switch cap {
        case .butt: try outer.append(to: stop, output: output)
        case .round:
            let center = pivot + parallel
            try outer.append(to: center, control: center + normal, weight: Float(0.707106781), output: output)
            try outer.append(to: stop, control: center - normal, weight: Float(0.707106781), output: output)
        case .square:
            let first = (pivot + normal) + parallel, second = (pivot - normal) + parallel
            if isLine { try outer.replaceLast(with: first, output: output) }
            else { try outer.append(to: first, output: output) }
            try outer.append(to: second, output: output)
            if isLine == false { try outer.append(to: stop, output: output) }
        }
    }
}
