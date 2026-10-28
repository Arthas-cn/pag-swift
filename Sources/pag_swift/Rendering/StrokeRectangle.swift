/// 固定PathKit整体矩形快路的Float边界；判定属于描边语义，不能交给CG的矩形识别代替。
struct StrokeRectangle: Sendable {
    /// firstCorner和thirdCorner排序后的左边界，保留源Float运算。
    let left: Float
    /// 排序后的上边界。
    let top: Float
    /// 排序后的右边界，普通成功矩形应大于left。
    let right: Float
    /// 排序后的下边界，普通成功矩形应大于top。
    let bottom: Float

    /// 扫描已接纳的完整规范化路径；仅源IsRectContour确认闭合矩形时返回，其他路径返回nil。
    static func detect(_ path: StrokePath, budget: inout GeometryBudget) throws -> Self? {
        try budget.consume()
        try budget.reserve(stride: 256)
        var scan = StrokeRectangleScan()
        var index = 0
        for verb in path.verbs {
            try budget.consume(1 + verb.pointCount)
            switch verb {
            case .move:
                let point = try scan.point(path.points[index])
                guard scan.move(to: point) else { return nil }
            case .line:
                let point = try scan.point(path.points[index])
                scan.last = point
                guard scan.line(to: point, closes: false) else { return nil }
            case .close:
                guard let first = scan.first else { return nil }
                scan.sawClose = true
                guard scan.line(to: first, closes: true) else { return nil }
            case .quad, .conic, .cubic: return nil
            }
            index += verb.pointCount
        }
        guard scan.sawClose, (3...4).contains(scan.directions.count), scan.closingEdgeIsAxial,
              let first = scan.firstCorner, let third = scan.thirdCorner else { return nil }
        return Self(left: min(first.x, third.x), top: min(first.y, third.y),
                    right: max(first.x, third.x), bottom: max(first.y, third.y))
    }
}

/// IsRectContour的allowPartial=false扫描状态；原最后Line点和当前扫描端点不能合并。
private struct StrokeRectangleScan {
    /// 连续同向边合并后的0...3方向，最多保留四个；相反方向的异或为2。
    var directions: [Int] = []
    /// 第一次有效边之前最后一个Move；后续Move不覆盖它。
    var first: SIMD2<Float>?
    /// 原始最后一个显式Line终点，Close不更新，用于最终斜闭合边校验。
    var last: SIMD2<Float>?
    /// 当前扫描边的起点；允许被Move改变，不能拿它代替原最后Line点。
    var current = SIMD2<Float>.zero
    /// 第二个方向开始处的角点，参与矩形边界计算。
    var firstCorner: SIMD2<Float>?
    /// 第三个方向目前到达的角点，同向附加Line会继续更新它。
    var thirdCorner: SIMD2<Float>?
    /// 曾见Close；源规则不会因尾随纯Move而清除此值。
    var sawClose = false
    /// 已Close或Move但还没有新的首条有效边；其后非零Line可能使整体矩形失效。
    var closedOrMoved = false

    /// 整体首点与最后显式Line之间不是斜线；两点相同也成立。
    var closingEdgeIsAxial: Bool {
        guard let first, let last else { return false }
        return first.x == last.x || first.y == last.y
    }

    /// 在首方向出现前更新起点，之后只允许符合源最终闭边校验的附加Move。
    mutating func move(to point: SIMD2<Float>) -> Bool {
        if directions.isEmpty { first = point }
        else if closingEdgeIsAxial == false { return false }
        current = point
        closedOrMoved = true
        return true
    }

    /// 接受零边和同向附加边，拒绝斜线、回折或超过四个方向；次序对应固定源码的早退。
    mutating func line(to end: SIMD2<Float>, closes: Bool) -> Bool {
        let delta = end - current
        guard delta.x.isFinite, delta.y.isFinite, delta.x == 0 || delta.y == 0 else { return false }
        if delta == .zero { return true }
        let direction = (delta.x != 0 ? 1 : 0) | (delta.x > 0 || delta.y > 0 ? 2 : 0)
        if directions.isEmpty {
            directions.append(direction)
            closedOrMoved = false
            current = end
            return true
        }
        guard closedOrMoved == false else { return false }
        // Close若与首边同向，不新增方向也不推进lineStart；源码允许从一条边中途开始的矩形。
        if sawClose, direction == directions[0] { return true }
        closedOrMoved = sawClose
        if directions.last == direction {
            if directions.count == 3, closes == false { thirdCorner = end }
            current = end
            return true
        }
        guard directions.count < 4 else { return false }
        directions.append(direction)
        switch directions.count {
        case 2: firstCorner = current
        case 3:
            guard directions[0] ^ directions[2] == 2 else { return false }
            thirdCorner = end
        case 4:
            guard directions[1] ^ directions[3] == 2 else { return false }
        default: return false
        }
        current = end
        return true
    }

    /// 几何构造前的源Float语义影子；不可表示时明确失败，不让NaN排序掩盖错误。
    func point(_ value: ScenePoint) throws -> SIMD2<Float> {
        let result = SIMD2(Float(value.x), Float(value.y))
        guard result.x.isFinite, result.y.isFinite else { throw PAGError.resourceLimitExceeded("geometryPrecision") }
        return result
    }
}
