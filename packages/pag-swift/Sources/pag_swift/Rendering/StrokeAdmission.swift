/// 一条规范化中心线子路径的只读范围与接纳信息；不复制点，也不决定dash之后的端帽。
struct StrokeSubpath: Sendable {
    /// 原路径里的完整指令区间，从Move开始，可包含结尾Close。
    let verbs: Range<Int>
    /// 指令引用的连续点区间，Close不占点。
    let points: Range<Int>
    /// Line/Close及全部曲线控制多边形的L1长度上界；零表示所有控制点重合。
    let lengthUpperBound: Double
    /// 除Move外至少有直线、曲线或Close；纯Move没有可描边内容。
    let hasSegments: Bool
    /// 输入末指令是否为Close；不能沿用来推断dash输出的闭合状态。
    let isClosed: Bool
}

/// 几何构造之前的纯Swift接纳结果；限制语义规模和本库存储，不替代后续实际细分计费。
struct StrokeAdmission: Sendable {
    /// 按原路径顺序保存的范围，所有独立Move都计入子路径限制。
    let subpaths: [StrokeSubpath]
    /// 含零on和接缝余量的理想dash片段数上界；实线为零。
    let dashPieceUpperBound: Int

    /// 扫描规范化中心线，输入/扩张/理想dash超限时在几何构造前失败，取消不发布部分结果。
    static func inspect(_ path: StrokePath, style: StrokeStyle, limits: StrokeBackendLimits = .standard,
                        budget: inout GeometryBudget) throws -> StrokeAdmission {
        try budget.consume()
        guard path.verbs.count <= limits.maximumInputVerbs else {
            throw PAGError.resourceLimitExceeded("maximumStrokeInputVerbs")
        }
        guard path.points.count <= limits.maximumInputPoints else {
            throw PAGError.resourceLimitExceeded("maximumStrokeInputPoints")
        }
        let expansion = try expansion(for: style, limits: limits)
        let cycle = try dashCycle(for: style.dashes)
        var contours: [StrokeSubpath] = []
        var pending: StrokeAdmissionContour?
        var pointIndex = 0
        var dashPieces = 0
        for (verbIndex, verb) in path.verbs.enumerated() {
            try budget.consume(1 + verb.pointCount)
            for index in pointIndex..<(pointIndex + verb.pointCount) {
                let point = path.points[index]
                try limits.check(point)
                // 不只分别检查坐标和半径；两者都合法仍可能产生超出接纳范围的理想轮廓。
                let magnitude = max(abs(point.x), abs(point.y))
                let bound = try StrokeInterval(magnitude).adding(StrokeInterval(expansion)).upper
                guard bound <= limits.maximumMagnitude else {
                    throw PAGError.resourceLimitExceeded("maximumStrokeMagnitude")
                }
            }
            if verb == .move {
                if let pending {
                    try append(pending, endVerb: verbIndex, endPoint: pointIndex, cycle: cycle,
                               onCount: (style.dashes?.intervals.count ?? 0) / 2, limits: limits,
                               contours: &contours, dashPieces: &dashPieces, budget: &budget)
                }
                pending = StrokeAdmissionContour(verb: verbIndex, point: pointIndex, start: path.points[pointIndex])
            } else {
                // 此入口只接受StrokeCenterline产物；默默补Move会使已计算的范围和成本失真。
                guard pending != nil, pending?.isClosed == false else {
                    throw PAGError.invalidArgument("unnormalizedStrokePath")
                }
                try pending?.append(verb, path: path, pointIndex: pointIndex)
            }
            pointIndex += verb.pointCount
        }
        if let pending {
            try append(pending, endVerb: path.verbs.count, endPoint: pointIndex, cycle: cycle,
                       onCount: (style.dashes?.intervals.count ?? 0) / 2, limits: limits,
                       contours: &contours, dashPieces: &dashPieces, budget: &budget)
        }
        try budget.reserve(stride: 64)
        return StrokeAdmission(subpaths: contours, dashPieceUpperBound: dashPieces)
    }

    /// 检查实际参与描边的宽度和扩张；非miter接角不使用无关miter值，hairline没有扩张。
    private static func expansion(for style: StrokeStyle, limits: StrokeBackendLimits) throws -> Double {
        guard style.width.isFinite, style.width > 0 else { throw PAGError.invalidArgument("strokeStyle") }
        guard style.width <= limits.maximumMagnitude else { throw PAGError.resourceLimitExceeded("maximumStrokeMagnitude") }
        if style.isHairline { return 0 }
        let radius = try StrokeInterval(style.width).scaled(by: 0.5)
        var bound = radius.upper
        if style.cap == .square {
            // 任意方向的square端点角可离端点sqrt(2)*radius；只取radius会低估斜线。
            bound = try radius.scaled(by: Double(2).squareRoot().nextUp).upper
        }
        if style.join == .miter {
            guard style.miterLimit.isFinite, style.miterLimit >= 0 else { throw PAGError.invalidArgument("strokeStyle") }
            bound = max(bound, try radius.scaled(by: style.miterLimit).upper)
        }
        return bound
    }

    /// 用实际Double间隔的实数和向下包围周期；Float period只属于phase规范化，不能作为成本分母。
    private static func dashCycle(for pattern: StrokeDashPattern?) throws -> StrokeInterval? {
        guard let pattern else { return nil }
        guard (2...16).contains(pattern.intervals.count), pattern.intervals.count.isMultiple(of: 2),
              pattern.period.isFinite, pattern.period > 0, pattern.phase.isFinite,
              pattern.phase >= 0, pattern.phase < pattern.period else { throw PAGError.invalidArgument("strokeDashPattern") }
        var cycle = StrokeInterval.zero
        for value in pattern.intervals {
            guard value.isFinite, value >= 0 else { throw PAGError.invalidArgument("strokeDashPattern") }
            cycle = try cycle.adding(StrokeInterval(value))
        }
        guard cycle.lower > 0 else { throw PAGError.invalidArgument("strokeDashPattern") }
        return cycle
    }

    /// 关闭一个扫描范围并在增长前计费；含退化绘制指令也可保守计dash余量，但不因此制造端帽。
    private static func append(_ pending: StrokeAdmissionContour, endVerb: Int, endPoint: Int,
                               cycle: StrokeInterval?, onCount: Int, limits: StrokeBackendLimits,
                               contours: inout [StrokeSubpath], dashPieces: inout Int,
                               budget: inout GeometryBudget) throws {
        try budget.consume()
        guard contours.count < limits.maximumSubpaths else { throw PAGError.resourceLimitExceeded("maximumStrokeSubpaths") }
        if let cycle, pending.hasSegments {
            let quotient = try StrokeInterval(pending.length).divided(by: cycle).upper.rounded(.up)
            let remaining = limits.maximumDashPieces - dashPieces
            // 先比限额再转换；自定义Int.max策略也不能让Double向Int的转换陷阱。
            guard quotient <= Double(remaining), let cycles = Int(exactly: quotient) else {
                throw PAGError.resourceLimitExceeded("maximumStrokeDashPieces")
            }
            let extra = cycles.addingReportingOverflow(2)
            let pieces = extra.partialValue.multipliedReportingOverflow(by: onCount)
            guard !extra.overflow, !pieces.overflow, pieces.partialValue <= remaining else {
                throw PAGError.resourceLimitExceeded("maximumStrokeDashPieces")
            }
            dashPieces += pieces.partialValue
        }
        try budget.reserve(stride: 128)
        contours.append(StrokeSubpath(verbs: pending.firstVerb..<endVerb, points: pending.firstPoint..<endPoint,
            lengthUpperBound: pending.length, hasSegments: pending.hasSegments, isClosed: pending.isClosed))
    }
}

/// 单条子路径的临时扫描状态；长度按L1控制多边形向上计量，不调用系统测量器。
private struct StrokeAdmissionContour {
    /// 该Move在原指令数组里的下标。
    let firstVerb: Int
    /// Move起点在原点数组里的下标。
    let firstPoint: Int
    /// Close应回到的Move起点。
    let start: ScenePoint
    /// 上一可绘制段的终点，初始为Move起点。
    var current: ScenePoint
    /// 已累计的有限非负长度上界。
    var length: Double = 0
    /// 已遇到直线、曲线或Close；即使长度为零也保留该信息。
    var hasSegments = false
    /// 已遇到Close，后续非Move由外层拒绝。
    var isClosed = false

    /// 从已经验证的Move建立零长度扫描状态。
    init(verb: Int, point: Int, start: ScenePoint) {
        firstVerb = verb
        firstPoint = point
        self.start = start
        current = start
    }

    /// 累加完整控制多边形或闭合边；调用方已按点数量计工作预算并验证坐标。
    mutating func append(_ verb: StrokePathVerb, path: StrokePath, pointIndex: Int) throws {
        hasSegments = true
        if verb == .close {
            try addDistance(to: start)
            isClosed = true
        } else {
            // Quad/正权重Conic用两条控制边，Cubic用三条；端点重合不意味着没有弧长。
            for index in pointIndex..<(pointIndex + verb.pointCount) { try addDistance(to: path.points[index]) }
        }
    }

    /// 向上包围精确Double端点差的L1距离及累计和，完全重合的边保持精确零。
    private mutating func addDistance(to point: ScenePoint) throws {
        let x = try StrokeInterval(point.x).subtracting(StrokeInterval(current.x)).maximumMagnitude
        let y = try StrokeInterval(point.y).subtracting(StrokeInterval(current.y)).maximumMagnitude
        let distance = try StrokeInterval(x).adding(StrokeInterval(y))
        length = try StrokeInterval(length).adding(distance).upper
        current = point
    }
}
