/// 以同高度精确符号约束扫描交点；叉积只作快速候选，不承担存在性或最终精度证明。
enum ScanIntersection {
    /// 返回内部交点事件；端点/共线返回nil，预算、取消或无法证明的数值状态向上传播。
    static func height(_ first: ScanBoundary, _ second: ScanBoundary,
                       budget: inout GeometryBudget) throws -> Double? {
        try budget.consume(16)
        let lower = max(first.lower.y, second.lower.y)
        let upper = min(first.upper.y, second.upper.y)
        guard lower < upper else { return nil }
        // 线性差在共同端点已为零，不可能还有另一个孤立内部根。
        if first.lower == second.lower || first.upper == second.upper { return nil }
        // 零的相邻值是最小subnormal；直接走域包围，避免为可选快探针制造不可保真的乘积。
        if let y = candidate(first, second), y != 0, y > lower, y < upper {
            let low = max(lower, y.nextDown), high = min(upper, y.nextUp)
            let a = try ScanBoundary.difference(first, second, at: low, budget: &budget)
            let b = try ScanBoundary.difference(first, second, at: high, budget: &budget)
            if a == 0 && b == 0 { return nil }
            // 单独的零值也可能是共线；另一个非零采样才证明它是唯一根。
            if a == 0 { return low > lower ? low : nil }
            if b == 0 { return high < upper ? high : nil }
            if a != b { return y }
        }
        let lowSign = try ScanBoundary.difference(first, second, at: lower, budget: &budget)
        let highSign = try ScanBoundary.difference(first, second, at: upper, budget: &budget)
        guard lowSign * highSign == -1 else { return nil }
        let y = try refine(first, second, lower: lower, upper: upper, lowerSign: lowSign, budget: &budget)
        // 没有内部可表示高度时保留既有端点level；不能伪造中点或删除这个窄带。
        return y > lower && y < upper ? y : nil
    }

    /// 沿有限Double的单调位序收窄已证明异号的区间，至多64次就能到达相邻浮点值。
    private static func refine(_ first: ScanBoundary, _ second: ScanBoundary, lower: Double, upper: Double,
                               lowerSign: Int, budget: inout GeometryBudget) throws -> Double {
        var low = ordinal(lower), high = ordinal(upper)
        while high - low > 1 {
            try budget.consume()
            // 跨零的位序中点可能落到subnormal；先取精确0，此后单侧跨度至多63位。
            let middle = value(low) < 0 && value(high) > 0 ? ordinal(0) : low + (high - low) / 2
            let y = value(middle)
            let sign = try ScanBoundary.difference(first, second, at: y, budget: &budget)
            if sign == 0 { return y }
            if sign == lowerSign { low = middle }
            else { high = middle }
        }
        return value(low)
    }

    /// 将有限Double映射到递增整数；−0与+0相邻，数值相等不妨碍位序严格收窄。
    private static func ordinal(_ value: Double) -> UInt64 {
        let bits = value.bitPattern
        let sign: UInt64 = 1 << 63
        return bits & sign == 0 ? bits ^ sign : ~bits
    }

    /// 还原位序；调用方只取两个有限端点之间的整数，不会构造NaN或无穷。
    private static func value(_ ordinal: UInt64) -> Double {
        let sign: UInt64 = 1 << 63
        return Double(bitPattern: ordinal & sign == 0 ? ~ordinal : ordinal ^ sign)
    }

    /// 复用旧归一化叉积估计高度；任何退化都回到域端点证明，不能在此宣称无交点。
    private static func candidate(_ first: ScanBoundary, _ second: ScanBoundary) -> Double? {
        let rx = first.upper.x - first.lower.x, ry = first.upper.y - first.lower.y
        let sx = second.upper.x - second.lower.x, sy = second.upper.y - second.lower.y
        let qx = second.lower.x - first.lower.x, qy = second.lower.y - first.lower.y
        let scale = max(abs(rx), abs(ry), abs(sx), abs(sy), abs(qx), abs(qy))
        guard scale > 0, scale.isFinite else { return nil }
        let r = ScenePoint(x: rx / scale, y: ry / scale)
        let s = ScenePoint(x: sx / scale, y: sy / scale)
        let q = ScenePoint(x: qx / scale, y: qy / scale)
        let denominator = r.x * s.y - r.y * s.x
        guard denominator != 0 else { return nil }
        let t = (q.x * s.y - q.y * s.x) / denominator
        let y = first.lower.y.addingProduct(t, ry)
        return y.isFinite ? y : nil
    }
}
