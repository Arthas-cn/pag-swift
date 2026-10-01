/// 已验证曲线路径的一条轮廓范围；只描述结构，不携带描边接纳或长度上界政策。
struct CurveContourRange: Sendable {
    /// 从Move到下一Move之前的指令范围，至少包含一个Move。
    let verbs: Range<Int>
    /// 对应的连续点范围，包含起点，Close不额外消费点。
    let points: Range<Int>
    /// 最后一条指令是否Close；提取出的新路径不能直接沿用此闭合标志。
    let isClosed: Bool
}

/// 在已通过StrokePath验证的曲线上建立轮廓索引，供测量共用，不施加描边专项规模限制。
enum CurveContourIndex {
    /// 保留每个Move，包括连续和末尾Move；扫描/增长均先计费，错误或取消不发布部分索引。
    static func ranges(in path: StrokePath, budget: inout GeometryBudget) throws -> [CurveContourRange] {
        var result: [CurveContourRange] = []
        var pending: (verb: Int, point: Int)?
        var pointIndex = 0
        for (index, verb) in path.verbs.enumerated() {
            try budget.consume()
            if verb == .move {
                if let pending {
                    try append(from: pending, to: (index, pointIndex), path: path, result: &result, budget: &budget)
                }
                pending = (index, pointIndex)
            }
            pointIndex += verb.pointCount
        }
        if let pending {
            try append(from: pending, to: (path.verbs.count, pointIndex), path: path, result: &result, budget: &budget)
        }
        try budget.consume()
        return result
    }

    /// 将一次结构扫描确定的非空指令范围加入索引；不计算控制多边形或隐式闭合长度。
    private static func append(from start: (verb: Int, point: Int), to end: (verb: Int, point: Int),
                               path: StrokePath, result: inout [CurveContourRange],
                               budget: inout GeometryBudget) throws {
        try budget.consume()
        try budget.reserve(stride: 128)
        result.append(CurveContourRange(verbs: start.verb..<end.verb, points: start.point..<end.point,
                                        isClosed: path.verbs[end.verb - 1] == .close))
    }
}
