/// 描边虚线共用的同步Float测量内核；只累计距离记录，不保存原曲线或决定compact索引。
struct StrokeDashMetric {
    /// 逐叶累加的有限非负距离；不以Double补回被Float舍入吞掉的增量。
    private(set) var distance: Float
    /// 距离严格递增的叶段记录；失败追加会删除自己的后缀，已有记录保持不变。
    private(set) var records: [StrokeDashRecord]

    /// 建立空测量表；数组增长及递归状态由追加操作的共享预算计费。
    init() {
        distance = 0
        records = []
    }

    /// 测量有限直线并关联外层非负曲线索引；数值、资源或取消失败不留下新增记录。
    mutating func appendLine(from start: SIMD2<Float>, to end: SIMD2<Float>,
                             curveIndex: Int, budget: inout GeometryBudget) throws {
        try updating(curveIndex: curveIndex, budget: &budget) { metric, sharedBudget in
            _ = try StrokeCurveMath.checked(start)
            _ = try StrokeCurveMath.checked(end)
            try metric.leaf(from: start, to: end, parameter: 0x3FFF_FFFF, curveIndex: curveIndex, budget: &sharedBudget)
        }
    }

    /// 测量原Float三次曲线，按源整数参数与控制点偏差细分；不改写外层保留的输出几何。
    mutating func appendCubic(from start: SIMD2<Float>, firstControl: SIMD2<Float>,
                              secondControl: SIMD2<Float>, to end: SIMD2<Float>,
                              curveIndex: Int, budget: inout GeometryBudget) throws {
        try updating(curveIndex: curveIndex, budget: &budget) { metric, sharedBudget in
            _ = try StrokeCurveMath.checked(start)
            _ = try StrokeCurveMath.checked(firstControl)
            _ = try StrokeCurveMath.checked(secondControl)
            _ = try StrokeCurveMath.checked(end)
            try metric.cubic(start, firstControl, secondControl, end, minimum: 0, maximum: 0x3FFF_FFFF,
                             depth: 0, curveIndex: curveIndex, budget: &sharedBudget)
        }
    }

    /// 测量原二次曲线及其实际半切子曲线；共线非匀速曲线也按参数偏差细分。
    mutating func append(_ curve: StrokeQuadCurve, curveIndex: Int, budget: inout GeometryBudget) throws {
        try updating(curveIndex: curveIndex, budget: &budget) { metric, sharedBudget in
            try metric.quad(curve, minimum: 0, maximum: 0x3FFF_FFFF, depth: 0,
                            curveIndex: curveIndex, budget: &sharedBudget)
        }
    }

    /// 测量原有理曲线的全局参数位置；根端点用存储值，不能改为Horner端点或子Conic求值。
    mutating func append(_ curve: StrokeConicCurve, curveIndex: Int, budget: inout GeometryBudget) throws {
        try updating(curveIndex: curveIndex, budget: &budget) { metric, sharedBudget in
            try metric.conic(curve, from: curve.start, to: curve.end, minimum: 0, maximum: 0x3FFF_FFFF,
                             depth: 0, curveIndex: curveIndex, budget: &sharedBudget)
        }
    }

    /// 同步借用自身和预算执行一次原子追加；错误只恢复记录与距离，已经花掉的工作与字节不退回。
    private mutating func updating(curveIndex: Int, budget: inout GeometryBudget,
                                   _ body: (inout Self, inout GeometryBudget) throws -> Void) throws {
        let previousCount = records.count, previousDistance = distance
        do {
            try budget.consume()
            guard curveIndex >= 0 else { throw PAGError.invalidArgument("strokeDashCurveIndex") }
            try body(&self, &budget)
        } catch {
            // 不保存数组快照，避免正常追加触发整表COW；取消后也必须完整恢复已有前缀。
            records.removeSubrange(previousCount..<records.count)
            distance = previousDistance
            throw error
        }
    }

    /// 固定SkContourMeasure的二次偏差与整数跨度；终止跨度不计算无用的曲率表达式。
    private mutating func quad(_ curve: StrokeQuadCurve, minimum: Int, maximum: Int, depth: Int,
                               curveIndex: Int, budget: inout GeometryBudget) throws {
        try budget.consume()
        if (maximum - minimum) >> 10 != 0,
           try Self.exceedsTolerance(curve.control * 0.5 - ((curve.start + curve.end) * 0.5) * 0.5) {
            guard depth < budget.maximumDepth else { throw PAGError.resourceLimitExceeded("maximumGeometryCurveDepth") }
            // split已为两个子值各预留128字节；同一对子值就是递归状态，不能重复收取成本。
            let pair = try curve.split(at: 0.5, budget: &budget)
            let middle = (minimum + maximum) >> 1
            try quad(pair.first, minimum: minimum, maximum: middle, depth: depth + 1, curveIndex: curveIndex, budget: &budget)
            try quad(pair.second, minimum: middle, maximum: maximum, depth: depth + 1, curveIndex: curveIndex, budget: &budget)
        } else {
            try leaf(from: curve.start, to: curve.end, parameter: maximum, curveIndex: curveIndex, budget: &budget)
        }
    }

    /// 原Conic只求全局mid，不切分权重；左右子树共享已求端点与同一个Float距离累计器。
    private mutating func conic(_ curve: StrokeConicCurve, from start: SIMD2<Float>, to end: SIMD2<Float>,
                                minimum: Int, maximum: Int, depth: Int, curveIndex: Int,
                                budget: inout GeometryBudget) throws {
        try budget.consume()
        let middle = (minimum + maximum) >> 1
        // 源顺序要求终止叶也先求mid；数值失败必须抛出，不能略过子树而发布残缺测量表。
        let point = try curve.position(at: Self.parameter(middle), budget: &budget)
        if (maximum - minimum) >> 10 != 0, try Self.exceedsTolerance(point - (start + end) * 0.5) {
            guard depth < budget.maximumDepth else { throw PAGError.resourceLimitExceeded("maximumGeometryCurveDepth") }
            try budget.reserve(2, stride: 128)
            try conic(curve, from: start, to: point, minimum: minimum, maximum: middle,
                      depth: depth + 1, curveIndex: curveIndex, budget: &budget)
            try conic(curve, from: point, to: end, minimum: middle, maximum: maximum,
                      depth: depth + 1, curveIndex: curveIndex, budget: &budget)
        } else {
            try leaf(from: start, to: end, parameter: maximum, curveIndex: curveIndex, budget: &budget)
        }
    }

    /// 既有三次测量算法共用同一记录出口；先检查跨度，再按源短路检查两个控制点。
    private mutating func cubic(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>,
                                minimum: Int, maximum: Int, depth: Int, curveIndex: Int,
                                budget: inout GeometryBudget) throws {
        try budget.consume()
        if (maximum - minimum) >> 10 != 0, try Self.cubicExceedsTolerance(a, b, c, d) {
            guard depth < budget.maximumDepth else { throw PAGError.resourceLimitExceeded("maximumGeometryCurveDepth") }
            try budget.reserve(2, stride: 128)
            let ab = try StrokeCurveMath.checked(a + (b - a) * 0.5)
            let bc = try StrokeCurveMath.checked(b + (c - b) * 0.5)
            let cd = try StrokeCurveMath.checked(c + (d - c) * 0.5)
            let abc = try StrokeCurveMath.checked(ab + (bc - ab) * 0.5)
            let bcd = try StrokeCurveMath.checked(bc + (cd - bc) * 0.5)
            let point = try StrokeCurveMath.checked(abc + (bcd - abc) * 0.5)
            let middle = (minimum + maximum) >> 1
            try cubic(a, ab, abc, point, minimum: minimum, maximum: middle,
                      depth: depth + 1, curveIndex: curveIndex, budget: &budget)
            try cubic(point, bcd, cd, d, minimum: middle, maximum: maximum,
                      depth: depth + 1, curveIndex: curveIndex, budget: &budget)
        } else {
            try leaf(from: a, to: d, parameter: maximum, curveIndex: curveIndex, budget: &budget)
        }
    }

    /// SkPoint::Length优先Float平方和，溢出则用Double求长后转回；下溢与累计不增长不入表。
    private mutating func leaf(from start: SIMD2<Float>, to end: SIMD2<Float>, parameter: Int,
                               curveIndex: Int, budget: inout GeometryBudget) throws {
        try budget.consume()
        let delta = end - start
        let squared = delta.x * delta.x + delta.y * delta.y
        let length: Float
        if squared.isFinite { length = squared.squareRoot() }
        else {
            // 平方溢出不代表长度不可表示；回退用原Float差，不能补救差值本身溢出或下溢。
            let x = Double(delta.x), y = Double(delta.y)
            length = Float((x * x + y * y).squareRoot())
        }
        let next = distance + length
        guard next.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        guard next > distance else { return }
        try budget.reserve(stride: 64)
        records.append(StrokeDashRecord(distance: next, curve: curveIndex, parameter: Self.parameter(parameter)))
        distance = next
    }

    /// 源三次谓词按第一个控制点优先短路，不为已决定细分的节点求无用的第二个偏差。
    private static func cubicExceedsTolerance(_ a: SIMD2<Float>, _ b: SIMD2<Float>,
                                              _ c: SIMD2<Float>, _ d: SIMD2<Float>) throws -> Bool {
        if try exceedsTolerance(a + (d - a) * (Float(1) / 3) - b) { return true }
        return try exceedsTolerance(a + (d - a) * (Float(2) / 3) - c)
    }

    /// 只接受有限的实际使用偏差；严格大于0.5才细分，不把NaN当作不弯曲。
    private static func exceedsTolerance(_ difference: SIMD2<Float>) throws -> Bool {
        let value = try StrokeCurveMath.checked(difference)
        return max(abs(value.x), abs(value.y)) > 0.5
    }

    /// 保留源整数转Float再乘倒数的次序；不同整数可舍到同一个Float参数，不能去重。
    private static func parameter(_ value: Int) -> Float { Float(value) * (1 / Float(0x3FFF_FFFF)) }
}
