/// 同一填充三角形的不可变空间索引；供后台准备和GPU覆盖查询，不保存最终像素。
struct RenderCoverageIndex: Sendable {
    /// 前序排列的BVH节点；空网格时为空，非空时根为下标0。
    let nodes: [RenderCoverageNode]
    /// 叶子连续区间中的源三角形序号，乘3即可定位源网格顶点。
    let triangles: [UInt32]
    /// CPU/GPU打包数组及必要元数据的保守成本。
    var estimatedBytes: Int { 128 + nodes.count * 64 + triangles.count * 8 }

    /// 用实际Float顶点建立平衡索引；有限范围、预算或取消失败时不发布部分树。
    static func prepare(_ mesh: RenderMesh, budget: inout GeometryBudget) throws -> RenderCoverageIndex {
        try budget.consume()
        try budget.reserve(stride: 128)
        guard mesh.vertices.count % 3 == 0 else { throw PAGError.renderingFailure("coverageTriangleCount") }
        let count = mesh.vertices.count / 3
        guard count <= Int(UInt32.max) / 2 else { throw PAGError.resourceLimitExceeded("coverageIndexCount") }
        try budget.reserve(count, stride: 96)
        var records: [CoverageTriangleRecord] = []
        records.reserveCapacity(count)
        for index in 0..<count {
            try budget.consume()
            let points = mesh.vertices[(index * 3)..<(index * 3 + 3)].map { SIMD2(Float($0.x), Float($0.y)) }
            guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                throw PAGError.renderingFailure("coverageNonFinite")
            }
            let bounds = SIMD4(min(points[0].x, points[1].x, points[2].x), min(points[0].y, points[1].y, points[2].y),
                               max(points[0].x, points[1].x, points[2].x), max(points[0].y, points[1].y, points[2].y))
            records.append(CoverageTriangleRecord(index: UInt32(index), bounds: bounds))
        }
        var builder = CoverageIndexBuilder(records: records)
        if count > 0 { try builder.build(0..<count, depth: 0, budget: &budget) }
        try Task.checkCancellation()
        return RenderCoverageIndex(nodes: builder.nodes, triangles: builder.triangles)
    }
}

/// Swift/MSL共享的32字节BVH节点；跳转值均为数组下标，不保存指针。
struct RenderCoverageNode: Sendable {
    /// 局部Float坐标的(minX,minY,maxX,maxY)，包含所有实际上传顶点。
    let bounds: SIMD4<Float>
    /// (首三角形索引,叶子数量,子树结束下标,0)；数量0表示分支，下一节点为其首子节点。
    var range: SIMD4<UInt32>
}

/// 构建期三角形元数据；不复制源顶点，中心用Double计算以避免Float相加溢出。
private struct CoverageTriangleRecord {
    /// 原始三角形序号，作为相同中心的确定性排序次键。
    let index: UInt32
    /// 实际上传顶点的有限包围范围。
    let bounds: SIMD4<Float>

    /// 返回指定轴范围的中心，不因大同号坐标相加产生无穷。
    func center(axis: Int) -> Double { Double(bounds[axis]) * 0.5 + Double(bounds[axis + 2]) * 0.5 }

    /// 中心相同仍按源序号全序比较，重复三角形不会造成划分停滞。
    func precedes(_ other: CoverageTriangleRecord, axis: Int) -> Bool {
        let first = center(axis: axis), second = other.center(axis: axis)
        return first == second ? index < other.index : first < second
    }
}

/// 单次有界BVH构建器；中位数原位划分，避免每层复制和完整排序全部三角形。
private struct CoverageIndexBuilder {
    /// 可重排的轻量记录，源网格始终不可变。
    var records: [CoverageTriangleRecord]
    /// 前序输出，父节点在子树完成后才写入结束下标。
    var nodes: [RenderCoverageNode] = []
    /// 每个三角形只进入一个叶子区间，没有按跨格次数膨胀的列表。
    var triangles: [UInt32] = []

    /// 递归构建严格缩小的范围，深度上限32；默认每叶最多4个三角形。
    mutating func build(_ range: Range<Int>, depth: Int, budget: inout GeometryBudget) throws {
        try budget.consume()
        guard depth <= 32 else { throw PAGError.resourceLimitExceeded("coverageIndexDepth") }
        var bounds = records[range.lowerBound].bounds
        for index in range.dropFirst() {
            try budget.consume()
            let value = records[index].bounds
            bounds = SIMD4(min(bounds.x, value.x), min(bounds.y, value.y), max(bounds.z, value.z), max(bounds.w, value.w))
        }
        try budget.reserve(stride: 64)
        let node = nodes.count
        nodes.append(RenderCoverageNode(bounds: bounds, range: .zero))
        if range.count <= 4 {
            try budget.reserve(range.count, stride: 8)
            let first = triangles.count
            for index in range { triangles.append(records[index].index) }
            nodes[node].range = SIMD4(UInt32(first), UInt32(range.count), UInt32(nodes.count), 0)
            return
        }
        let xSpan = Double(bounds.z) - Double(bounds.x), ySpan = Double(bounds.w) - Double(bounds.y)
        let middle = range.lowerBound + range.count / 2
        try partition(range, around: middle, axis: xSpan >= ySpan ? 0 : 1, budget: &budget)
        try build(range.lowerBound..<middle, depth: depth + 1, budget: &budget)
        try build(middle..<range.upperBound, depth: depth + 1, budget: &budget)
        // 前序布局允许GPU直接跳过整棵不相交子树，无需片元私有递归栈。
        nodes[node].range.z = UInt32(nodes.count)
    }

    /// 迭代quickselect只保证中位数两侧的顺序关系；最坏输入由统一工作量预算限制。
    private mutating func partition(_ range: Range<Int>, around median: Int, axis: Int,
                                    budget: inout GeometryBudget) throws {
        var lower = range.lowerBound, upper = range.upperBound - 1
        while lower < upper {
            try budget.consume()
            let pivot = records[lower + (upper - lower) / 2]
            var left = lower, right = upper
            while left <= right {
                while left <= upper {
                    try budget.consume()
                    if !records[left].precedes(pivot, axis: axis) { break }
                    left += 1
                }
                while right >= lower {
                    try budget.consume()
                    if !pivot.precedes(records[right], axis: axis) { break }
                    right -= 1
                }
                if left <= right {
                    records.swapAt(left, right)
                    left += 1
                    right -= 1
                }
            }
            if median <= right { upper = right }
            else if median >= left { lower = left }
            else { return }
        }
    }
}
