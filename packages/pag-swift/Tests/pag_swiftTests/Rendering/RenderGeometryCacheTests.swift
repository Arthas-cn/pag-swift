import Testing
@testable import pag_swift

/// 几何 LRU 的对象身份、精度复用、保活和资源上限，避免每帧重新准备静态轮廓。
struct RenderGeometryCacheTests {
    /// 同一来源的颜色外置、平移与同档缩放共用网格；跨档缩放和新对象创建独立结果。
    @Test func identityAndPrecisionControlReuse() throws {
        let source = makeSource()
        var cache = try RenderGeometryCache()
        let first = try mesh(source, cache: &cache)
        let translated = try mesh(source, transform: .translation(x: 200, y: 100), cache: &cache)
        let zoom = try mesh(source, transform: .scale(x: 1.5, y: 1.5), cache: &cache)
        let sameZoom = try mesh(source, transform: .scale(x: 2, y: 2), cache: &cache)
        let another = try mesh(makeSource(), cache: &cache)
        #expect(first === translated && zoom === sameZoom)
        #expect(first !== zoom && another !== first && cache.count == 3)
    }

    /// 最近访问的节点留下，最旧节点在第三项进入时淘汰；清空只释放缓存的所有权。
    @Test func evictionUsesAccessOrderAndExactAccounting() throws {
        let a = makeSource(), b = makeSource(), c = makeSource()
        var measure = try RenderGeometryCache()
        let retained = try mesh(a, cache: &measure)
        let oneCost = measure.byteCount
        var cache = try RenderGeometryCache(byteLimit: oneCost * 2)
        let firstA = try mesh(a, cache: &cache)
        let firstB = try mesh(b, cache: &cache)
        #expect(cache.byteCount == oneCost * 2 && cache.count == 2)
        #expect(try mesh(a, cache: &cache) === firstA)
        _ = try mesh(c, cache: &cache)
        #expect(try mesh(a, cache: &cache) === firstA)
        #expect(try mesh(b, cache: &cache) !== firstB)
        #expect(cache.byteCount == oneCost * 2 && cache.count == 2)
        cache.removeAll()
        #expect(cache.byteCount == 0 && cache.count == 0 && !retained.vertices.isEmpty)
    }

    /// 源对象必须一直保活到条目移除，防止地址复用把新路径误命中旧网格。
    @Test func cacheKeepsSourceAliveUntilRemoval() throws {
        var cache = try RenderGeometryCache()
        weak var weakOutline: GlyphOutline?
        do {
            let outline = GeometryTestSupport.outline([GeometryTestSupport.rectangle(0, 0, 10, 10)])
            weakOutline = outline
            _ = try mesh(.glyph(outline), cache: &cache)
        }
        #expect(weakOutline != nil)
        cache.removeAll()
        #expect(weakOutline == nil)
    }

    /// 零预算与装不下的条目可成功准备但不留存，非法负预算明确拒绝。
    @Test func disabledAndOversizedEntriesAreNotRetained() throws {
        for limit in [0, 1] {
            var cache = try RenderGeometryCache(byteLimit: limit)
            let source = makeSource()
            let first = try mesh(source, cache: &cache)
            let second = try mesh(source, cache: &cache)
            #expect(first !== second && cache.count == 0 && cache.byteCount == 0)
        }
        #expect(throws: PAGError.invalidArgument("geometryCacheBytes")) { try RenderGeometryCache(byteLimit: -1) }
    }

    /// 已命中网格仍受当前请求的更低预算和取消约束，不把过期工作重新插入缓存。
    @Test func cachedResultsRespectBudgetAndCancellation() async throws {
        let source = makeSource()
        var cache = try RenderGeometryCache()
        _ = try mesh(source, cache: &cache)
        var tiny = try GeometryBudget(maximumBytes: 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try cache.mesh(for: source, transform: .identity, budget: &tiny)
        }
        let task = Task.detached {
            var localCache = try RenderGeometryCache()
            var budget = try GeometryBudget()
            _ = try localCache.mesh(for: source, transform: .identity, budget: &budget)
            withUnsafeCurrentTask { $0?.cancel() }
            return try localCache.mesh(for: source, transform: .identity, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cache.count == 1)
    }

    /// 每次创建相同内容但不同身份的不可变字形，便于区分内容与对象身份键。
    private func makeSource() -> RenderGeometrySource {
        .glyph(GeometryTestSupport.outline([GeometryTestSupport.rectangle(0, 0, 10, 10)]))
    }

    /// 每次请求使用独立准备预算，复用同一个 owner 局部 LRU。
    private func mesh(_ source: RenderGeometrySource, transform: SceneAffine = .identity,
                      cache: inout RenderGeometryCache) throws -> RenderMesh {
        var budget = try GeometryBudget()
        return try cache.mesh(for: source, transform: transform, budget: &budget)
    }
}
