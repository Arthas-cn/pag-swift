import Testing
@testable import pag_swift

/// 多源蒙版网格缓存的有序键、同值复用和零verb歧义门禁；不创建Metal附件。
struct MaskBooleanCacheTests {
    /// 相同路径对象与相同操作复用网格，改后续模式或反向位必须另建结果。
    @Test func compositeIdentityIncludesAllTermsAndOperations() throws {
        let first = try ShapePathFixtures.square(10)
        let second = try SourcePath(verbs: [.move, .line, .line, .line, .close], points: [
            ScenePoint(x: 15, y: 10), ScenePoint(x: 25, y: 10),
            ScenePoint(x: 25, y: 20), ScenePoint(x: 15, y: 20)
        ])
        let union = try expression(first, second, mode: .add)
        let same = try expression(first, second, mode: .add)
        let intersect = try expression(first, second, mode: .intersect)
        let inverse = try expression(first, second, mode: .add, inverted: true)
        var cache = try RenderGeometryCache()
        var budget = try GeometryBudget()
        let firstMesh = try cache.mesh(for: .maskExpression(union), transform: .identity, budget: &budget)
        let reused = try cache.mesh(for: .maskExpression(same), transform: .translation(x: 40, y: 70), budget: &budget)
        let overlap = try cache.mesh(for: .maskExpression(intersect), transform: .identity, budget: &budget)
        let inverted = try cache.mesh(for: .maskExpression(inverse), transform: .identity, budget: &budget)
        #expect(firstMesh === reused && cache.count == 3)
        #expect(overlap !== firstMesh && inverted !== firstMesh)
        #expect(GeometryTestSupport.area(firstMesh) == 150)
        #expect(GeometryTestSupport.area(overlap) == 50)
        #expect(RenderGeometrySource.maskExpression(union).estimatedBytes == union.estimatedBytes)
    }

    /// 两条相同路径XOR后虽无面积，不能仅凭空网格猜PathKit是否留下零verb。
    @Test func ambiguousEmptyResultFailsBeforeCacheInsertion() throws {
        let path = try ShapePathFixtures.square(10)
        let expression = try self.expression(path, path, mode: .difference)
        var cache = try RenderGeometryCache()
        var budget = try GeometryBudget()
        #expect(throws: PAGError.unsupportedFeature("maskBooleanEmptyResult")) {
            try cache.mesh(for: .maskExpression(expression), transform: .identity, budget: &budget)
        }
        #expect(cache.count == 0)
    }

    /// 交换源顺序后减法区域变化，缓存键不能因两条路径集合相同而误命中。
    @Test func changingSourceOrderUsesDifferentMesh() throws {
        let first = try ShapePathFixtures.square(10)
        let second = try SourcePath(verbs: [.move, .line, .line, .line, .close], points: [
            ScenePoint(x: 15, y: 10), ScenePoint(x: 25, y: 10),
            ScenePoint(x: 25, y: 20), ScenePoint(x: 15, y: 20)
        ])
        let forward = try expression(first, second, mode: .subtract)
        let backward = try expression(second, first, mode: .subtract)
        var cache = try RenderGeometryCache()
        var budget = try GeometryBudget()
        let left = try cache.mesh(for: .maskExpression(forward), transform: .identity, budget: &budget)
        let right = try cache.mesh(for: .maskExpression(backward), transform: .identity, budget: &budget)
        #expect(cache.count == 2 && left !== right)
        #expect(GeometryTestSupport.coverage(left, at: .init(x: 12.37, y: 15.29)) == 1)
        #expect(GeometryTestSupport.coverage(right, at: .init(x: 12.37, y: 15.29)) == 0)
    }

    /// 同一路径的不同Float扩张值必须使用不同缓存键；相同值在平移后仍复用网格。
    @Test func sampledExpansionBitsPartitionGeometryCache() throws {
        let path = try ShapePathFixtures.square(10)
        let narrow = try SampledMaskExpression(terms: [.init(path: path, mode: .add,
                                                             isInverted: false, expansion: 1)])
        let wide = try SampledMaskExpression(terms: [.init(path: path, mode: .add,
                                                           isInverted: false, expansion: 2)])
        var cache = try RenderGeometryCache()
        var budget = try GeometryBudget()
        let first = try cache.mesh(for: .maskExpression(narrow), transform: .identity, budget: &budget)
        let reused = try cache.mesh(for: .maskExpression(narrow),
                                    transform: .translation(x: 30, y: 40), budget: &budget)
        let second = try cache.mesh(for: .maskExpression(wide), transform: .identity, budget: &budget)
        #expect(first === reused && first !== second && cache.count == 2)
        #expect(GeometryTestSupport.coverage(first, at: .init(x: 8.5, y: 15)) == 0)
        #expect(GeometryTestSupport.coverage(second, at: .init(x: 8.5, y: 15)) == 1)
    }

    /// 复合缓存持有全部源路径到移除时；命中还要支付键构建与返回网格的当前请求预算。
    @Test func retainedSourcesAndHitBudgetRemainBounded() throws {
        var cache = try RenderGeometryCache()
        var meshBytes = 0
        weak var firstPath: SourcePath?
        weak var secondPath: SourcePath?
        do {
            let first = try ShapePathFixtures.square(10)
            let second = try ShapePathFixtures.square(20)
            firstPath = first
            secondPath = second
            let value = try expression(first, second, mode: .add)
            var initial = try GeometryBudget()
            let mesh = try cache.mesh(for: .maskExpression(value), transform: .identity, budget: &initial)
            meshBytes = mesh.estimatedBytes
            var exactHit = try GeometryBudget(maximumBytes: meshBytes + 64)
            #expect(try cache.mesh(for: .maskExpression(value), transform: .identity,
                                   budget: &exactHit) === mesh)
            var tinyHit = try GeometryBudget(maximumBytes: meshBytes + 63)
            #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
                try cache.mesh(for: .maskExpression(value), transform: .identity, budget: &tinyHit)
            }
            let source = RenderGeometrySource.maskExpression(value)
            let precision = try GeometryPrecision(transform: .identity)
            var measured = try GeometryBudget()
            _ = try source.prepare(precision: precision, budget: &measured)
            var exactMiss = try GeometryBudget(maximumBytes: measured.usedBytes)
            #expect(try source.prepare(precision: precision, budget: &exactMiss).vertices.count > 0)
            var tinyMiss = try GeometryBudget(maximumBytes: measured.usedBytes - 1)
            #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
                try source.prepare(precision: precision, budget: &tinyMiss)
            }
        }
        #expect(meshBytes > 128 && firstPath != nil && secondPath != nil)
        cache.removeAll()
        #expect(firstPath == nil && secondPath == nil)
    }

    /// 用两条真实源对象构造不可变表达式，避免测试通过临时合并轮廓绕过缓存键。
    private func expression(_ first: SourcePath, _ second: SourcePath, mode: SourceMaskMode,
                            inverted: Bool = false) throws -> SampledMaskExpression {
        try SampledMaskExpression(terms: [SampledMaskTerm(path: first, mode: .add, isInverted: false),
                                          SampledMaskTerm(path: second, mode: mode, isInverted: inverted)])
    }
}
