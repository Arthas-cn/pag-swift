import Testing
@testable import pag_swift

/// BVH必须保留全部候选三角形、正确跳过子树，并在预算/取消时停止；不代表AA画面已完成。
struct RenderCoverageIndexTests {
    /// 分散三角形只返回邻近候选，每个源三角形恰好出现一次且节点出口严格前进。
    @Test func spatialQueriesMatchExhaustiveBounds() throws {
        let mesh = triangles(count: 257)
        var budget = try GeometryBudget()
        let index = try RenderCoverageIndex.prepare(mesh, budget: &budget)
        #expect(MemoryLayout<RenderCoverageNode>.stride == 32)
        #expect(MemoryLayout<RenderCoverageNode>.offset(of: \.range) == 16)
        #expect(index.triangles.sorted() == Array(UInt32(0)..<257))
        #expect(index.nodes[0].range.z == index.nodes.count)
        for (position, node) in index.nodes.enumerated() {
            #expect(node.range.z > position && node.range.z <= index.nodes.count)
            #expect(node.range.y <= 4)
        }
        for x in stride(from: -2, through: 770, by: 7) {
            let query = SIMD4<Float>(Float(x), -1, Float(x + 2), 2)
            let candidates = queryIndex(index, box: query)
            var expected: Set<UInt32> = []
            for id in 0..<257 where id * 3 + 1 >= x && id * 3 <= x + 2 { expected.insert(UInt32(id)) }
            #expect(expected.isSubset(of: candidates))
            #expect(candidates.count <= 8)
        }
    }

    /// 中心全部相同仍能平衡划分，遍历无环且不漏掉重复源三角形。
    @Test func coincidentCentersTerminateWithoutDroppingInputs() throws {
        let points = [ScenePoint(x: 0, y: 0), ScenePoint(x: 1, y: 0), ScenePoint(x: 0, y: 1)]
        let mesh = RenderMesh(origin: .zero, vertices: Array(repeating: points, count: 129).flatMap { $0 })
        var budget = try GeometryBudget()
        let index = try RenderCoverageIndex.prepare(mesh, budget: &budget)
        #expect(queryIndex(index, box: SIMD4(-1, -1, 2, 2)).count == 129)
        #expect(index.nodes.count < 129 && index.nodes.count > 1)
    }

    /// 包围范围按照转换后的Float顶点，而非较窄的Double输入截断值建立。
    @Test func boundsContainRoundedGPUCoordinates() throws {
        let x = 16_777_219.0
        let mesh = RenderMesh(origin: .zero, vertices: [ScenePoint(x: x, y: 0), ScenePoint(x: x + 3, y: 0), ScenePoint(x: x, y: 4)])
        var budget = try GeometryBudget()
        let index = try RenderCoverageIndex.prepare(mesh, budget: &budget)
        #expect(index.nodes[0].bounds.x == Float(x) && index.nodes[0].bounds.z == Float(x + 3))
    }

    /// 空输入合法；损坏三角形、不可表示Float和不足预算分别明确失败。
    @Test func invalidAndLimitedInputsFailWithoutPartialIndex() throws {
        var budget = try GeometryBudget()
        let empty = try RenderCoverageIndex.prepare(RenderMesh(origin: .zero, vertices: []), budget: &budget)
        #expect(empty.nodes.isEmpty && empty.triangles.isEmpty)
        #expect(throws: PAGError.renderingFailure("coverageTriangleCount")) {
            try RenderCoverageIndex.prepare(RenderMesh(origin: .zero, vertices: [.zero]), budget: &budget)
        }
        var tiny = try GeometryBudget(maximumBytes: 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try RenderCoverageIndex.prepare(triangles(count: 1), budget: &tiny)
        }
        var work = try GeometryBudget(maximumWork: 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try RenderCoverageIndex.prepare(triangles(count: 20), budget: &work)
        }
        let huge = RenderMesh(origin: .zero, vertices: [ScenePoint(x: .greatestFiniteMagnitude, y: 0), .zero, ScenePoint(x: 1, y: 1)])
        #expect(throws: PAGError.renderingFailure("coverageNonFinite")) { try RenderCoverageIndex.prepare(huge, budget: &budget) }
    }

    /// 已取消的准备在进入记录循环前结束，不依赖计时等待。
    @Test func cancellationStopsPreparation() async throws {
        let task = Task {
            var budget = try GeometryBudget()
            withUnsafeCurrentTask { $0?.cancel() }
            return try RenderCoverageIndex.prepare(triangles(count: 100), budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 创建彼此分开的语义三角形，用独立解析范围对照BVH结果。
    private func triangles(count: Int) -> RenderMesh {
        RenderMesh(origin: .zero, vertices: (0..<count).flatMap { id in
            let x = Double(id * 3)
            return [ScenePoint(x: x, y: 0), ScenePoint(x: x + 1, y: 0), ScenePoint(x: x, y: 1)]
        })
    }

    /// 按GPU拟用的子树出口无栈遍历；独立限制访问次数以发现错误环。
    private func queryIndex(_ index: RenderCoverageIndex, box: SIMD4<Float>) -> Set<UInt32> {
        var result: Set<UInt32> = [], position = 0, visits = 0
        while position < index.nodes.count, visits <= index.nodes.count {
            visits += 1
            let node = index.nodes[position]
            if node.bounds.x > box.z || node.bounds.z < box.x || node.bounds.y > box.w || node.bounds.w < box.y {
                position = Int(node.range.z)
            } else if node.range.y == 0 { position += 1 }
            else {
                result.formUnion(index.triangles[Int(node.range.x)..<Int(node.range.x + node.range.y)])
                position = Int(node.range.z)
            }
        }
        #expect(visits <= index.nodes.count)
        return result
    }
}
