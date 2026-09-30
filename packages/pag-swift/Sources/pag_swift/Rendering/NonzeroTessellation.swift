import Foundation

/// 将整个复合折线一次性按 nonzero 规则分解；不把孔洞或重叠轮廓分别混合。
enum NonzeroTessellation {
    /// 生成内部不重叠的三角形；所有边交点成为扫描边界，错误或取消不发布部分网格。
    static func prepare(_ contours: [[ScenePoint]], budget: inout GeometryBudget) throws -> RenderMesh {
        try budget.consume()
        guard let origin = try origin(of: contours, budget: &budget) else {
            return RenderMesh(origin: .zero, vertices: [])
        }
        var edges: [ScanBoundary] = []
        var levels: [Double] = []
        for contour in contours where contour.count >= 3 {
            for index in contour.indices {
                try budget.consume()
                let first = try local(contour[index], origin: origin)
                let second = try local(contour[(index + 1) % contour.count], origin: origin)
                // 水平边不与扫描带内部相交；端点仍由与它相连的非水平边提供。
                guard first.y != second.y else { continue }
                try budget.reserve(stride: 96)
                try budget.reserve(2, stride: 16)
                let edge = ScanBoundary(first, second)
                edges.append(edge)
                levels.append(edge.lower.y)
                levels.append(edge.upper.y)
            }
        }
        guard !edges.isEmpty else { return RenderMesh(origin: origin, vertices: []) }
        try budget.sorting(edges.count)
        edges.sort { $0.lower.y < $1.lower.y }
        try Task.checkCancellation()
        try addIntersections(edges, to: &levels, budget: &budget)
        try budget.sorting(levels.count)
        levels.sort()
        try Task.checkCancellation()
        // 在原数组压缩相同高度，避免为所有顶点与交点再分配一份峰值数组。
        var count = 0
        for index in levels.indices {
            try budget.consume()
            let level = levels[index]
            if count == 0 || levels[count - 1] != level {
                levels[count] = level
                count += 1
            }
        }
        levels.removeLast(levels.count - count)
        var vertices: [ScenePoint] = []
        var active: [ScanCrossing] = []
        try budget.reserve(edges.count, stride: 64)
        active.reserveCapacity(edges.count)
        try budget.reserve(edges.count, stride: 16)
        var eligible: [Int] = []
        eligible.reserveCapacity(edges.count)
        var nextEdge = 0
        for index in 1..<levels.count {
            try budget.consume()
            let lower = levels[index - 1], upper = levels[index]
            active.removeAll(keepingCapacity: true)
            // 每条边仅从原y序加入一次；后面的带不再扫描已永久结束的历史边。
            while nextEdge < edges.count, edges[nextEdge].lower.y <= lower {
                try budget.consume()
                eligible.append(nextEdge)
                nextEdge += 1
            }
            var remaining = 0
            // 按下标原地压缩，不能用持有旧数组副本的值迭代器触发逐带COW复制。
            for slot in eligible.indices {
                try budget.consume()
                let edgeIndex = eligible[slot]
                let edge = edges[edgeIndex]
                guard edge.upper.y >= upper else { continue }
                eligible[remaining] = edgeIndex
                remaining += 1
                // 相邻浮点高度之间未必还有可表示的 y；在两端求 x 后取均值仍可保留该窄带。
                active.append(ScanCrossing(lowerX: edge.x(at: lower), upperX: edge.x(at: upper), edge: edgeIndex))
            }
            eligible.removeLast(eligible.count - remaining)
            try budget.sorting(active.count)
            active.sort(by: ScanCrossing.precedes)
            try Task.checkCancellation()
            try fillBand(lower: lower, upper: upper, crossings: active, edges: edges,
                         vertices: &vertices, budget: &budget)
        }
        try Task.checkCancellation()
        return RenderMesh(origin: origin, vertices: vertices)
    }

    /// 有限包围盒左上角作为局部原点，减少巨大平移量在 GPU Float 顶点中的精度损失。
    private static func origin(of contours: [[ScenePoint]], budget: inout GeometryBudget) throws -> ScenePoint? {
        var minimum: ScenePoint?
        for contour in contours {
            for point in contour {
                try budget.consume()
                _ = try GeometryMath.checked(point)
                if let previous = minimum { minimum = ScenePoint(x: min(previous.x, point.x), y: min(previous.y, point.y)) }
                else { minimum = point }
            }
        }
        return minimum
    }

    /// 消去共同平移；若跨度本身无法表示则失败，不能饱和到任意有限坐标。
    private static func local(_ point: ScenePoint, origin: ScenePoint) throws -> ScenePoint {
        try GeometryMath.checked(ScenePoint(x: point.x - origin.x, y: point.y - origin.y))
    }

    /// 用较长包围轴收窄闭区间候选；原边数组不动，真正交点仍使用原下标顺序计算。
    private static func addIntersections(_ edges: [ScanBoundary], to levels: inout [Double],
                                         budget: inout GeometryBudget) throws {
        let projections = try projections(of: edges, budget: &budget)
        for first in projections.indices {
            try budget.consume()
            let a = projections[first]
            for second in (first + 1)..<projections.count {
                try budget.consume()
                let b = projections[second]
                // 必须严格大于：等于时可能涉及零宽竖边，仍由真正交点判定排除端点/共线。
                if b.lower > a.upper { break }
                if b.otherLower > a.otherUpper || a.otherLower > b.otherUpper { continue }
                let earlier = min(a.edge, b.edge), later = max(a.edge, b.edge)
                if let y = try ScanIntersection.height(edges[earlier], edges[later], budget: &budget) {
                    try budget.reserve(stride: 16)
                    levels.append(y)
                }
            }
        }
    }

    /// 建立单次有界投影索引；等长选Y并复用原序，X排序预付工作后在系统排序两端检查取消。
    private static func projections(of edges: [ScanBoundary], budget: inout GeometryBudget) throws -> [ScanProjection] {
        guard let first = edges.first else { return [] }
        var left = min(first.lower.x, first.upper.x), right = max(first.lower.x, first.upper.x)
        var top = first.lower.y, bottom = first.upper.y
        for edge in edges {
            try budget.consume()
            left = min(left, edge.lower.x, edge.upper.x)
            right = max(right, edge.lower.x, edge.upper.x)
            top = min(top, edge.lower.y)
            bottom = max(bottom, edge.upper.y)
        }
        let horizontal = right - left > bottom - top
        try budget.reserve(edges.count, stride: 48)
        var result: [ScanProjection] = []
        result.reserveCapacity(edges.count)
        for index in edges.indices {
            try budget.consume()
            let edge = edges[index]
            let x0 = min(edge.lower.x, edge.upper.x), x1 = max(edge.lower.x, edge.upper.x)
            result.append(ScanProjection(lower: horizontal ? x0 : edge.lower.y,
                upper: horizontal ? x1 : edge.upper.y, otherLower: horizontal ? edge.lower.y : x0,
                otherUpper: horizontal ? edge.upper.y : x1, edge: index))
        }
        if horizontal {
            try budget.sorting(result.count)
            result.sort { $0.lower == $1.lower ? $0.edge < $1.edge : $0.lower < $1.lower }
        }
        try Task.checkCancellation()
        return result
    }

    /// 将同一个扫描带中两端均重合的边一起累计，只在绕数从零进出时形成一个填充区间。
    private static func fillBand(lower: Double, upper: Double, crossings: [ScanCrossing], edges: [ScanBoundary],
                                 vertices: inout [ScenePoint], budget: inout GeometryBudget) throws {
        var winding = 0
        var left: Int?
        var index = 0
        while index < crossings.count {
            try budget.consume()
            let start = index
            let before = winding
            repeat {
                winding += edges[crossings[index].edge].winding
                index += 1
            } while index < crossings.count && crossings[index].lowerX == crossings[start].lowerX
                && crossings[index].upperX == crossings[start].upperX
            if before == 0, winding != 0 { left = crossings[start].edge }
            else if before != 0, winding == 0 {
                guard let left else { throw PAGError.renderingFailure("geometryWinding") }
                try trapezoid(left: edges[left], right: edges[crossings[start].edge], lower: lower, upper: upper,
                              vertices: &vertices, budget: &budget)
            }
        }
        guard winding == 0 else { throw PAGError.renderingFailure("geometryWinding") }
    }

    /// 同一填充区间最多两个三角形；反序端点必须通过相邻高度的交点证书。
    private static func trapezoid(left: ScanBoundary, right: ScanBoundary, lower: Double, upper: Double,
                                  vertices: inout [ScenePoint], budget: inout GeometryBudget) throws {
        let top = try ScanBoundary.ordered(left, right, at: lower, budget: &budget)
        let bottom = try ScanBoundary.ordered(left, right, at: upper, budget: &budget)
        let a = ScenePoint(x: top.0, y: lower), b = ScenePoint(x: top.1, y: lower)
        let c = ScenePoint(x: bottom.1, y: upper), d = ScenePoint(x: bottom.0, y: upper)
        if top.0 < top.1 {
            try budget.reserve(3, stride: 32)
            vertices.append(contentsOf: [a, b, c])
        }
        if bottom.0 < bottom.1 {
            try budget.reserve(3, stride: 32)
            vertices.append(contentsOf: [a, c, d])
        }
    }

}

/// 单条边在主轴与另一轴的闭包索引；只筛选不可能相交的边，不改变交点运算。
private struct ScanProjection {
    /// 较长包围轴上的最小端点坐标，排序主键。
    let lower: Double
    /// 同一轴上的最大端点坐标，可以等于lower。
    let upper: Double
    /// 另一轴上的最小坐标，用于闭包相交检查。
    let otherLower: Double
    /// 另一轴上的最大坐标，零宽边不被丢弃。
    let otherUpper: Double
    /// 原y序边下标，排序并列键及固定交点操作数顺序。
    let edge: Int
}

/// 一条活动边在扫描带中点的交点，只保存边下标，不复制轮廓。
private struct ScanCrossing {
    /// 扫描带下边界的 x；不是源边的较小 x。
    let lowerX: Double
    /// 扫描带上边界的 x，与 lowerX 共同决定是否重合。
    let upperX: Double
    /// 规范边数组下标。
    let edge: Int

    /// 中点 x 相同时按端点再比较，防止因均值舍入把不同的平行边合并成一条。
    static func precedes(_ first: ScanCrossing, _ second: ScanCrossing) -> Bool {
        let firstMiddle = first.lowerX * 0.5 + first.upperX * 0.5
        let secondMiddle = second.lowerX * 0.5 + second.upperX * 0.5
        if firstMiddle != secondMiddle { return firstMiddle < secondMiddle }
        if first.lowerX != second.lowerX { return first.lowerX < second.lowerX }
        if first.upperX != second.upperX { return first.upperX < second.upperX }
        return first.edge < second.edge
    }
}
