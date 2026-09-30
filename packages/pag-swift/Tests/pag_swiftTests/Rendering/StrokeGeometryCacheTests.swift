import Testing
@testable import pag_swift

/// 描边冷路径进入既有网格LRU；命中、资源失败和取消不能替换已经发布的有效网格。
struct StrokeGeometryCacheTests {
    /// 同一描边对象和平移命中网格，首次准备做完整几何工作；命中仅扣既有网格保活预算。
    @Test func warmStrokeMeshUsesExistingCacheIdentity() throws {
        let geometry = try StrokeGeometryTestSupport.circle(style: StrokeGeometryTestSupport.style(width: 0.5))
        var cache = try RenderGeometryCache()
        var cold = try GeometryBudget()
        let source = RenderGeometrySource.shape(geometry)
        let first = try cache.mesh(for: source, transform: .identity, budget: &cold)
        var warm = try GeometryBudget(maximumWork: 1)
        let second = try cache.mesh(for: source, transform: .translation(x: 30, y: -20), budget: &warm)
        #expect(first === second && !first.vertices.isEmpty && cache.count == 1)
        #expect(cold.work > warm.work && warm.work == 1)
    }

    /// 字节/工作失败不留新网格；后轮廓深度失败时也不能缓存前面已经完成的Line描边。
    @Test func failuresNeverInsertPartialStrokeMesh() throws {
        let line = try SourcePath(verbs: [.move, .line], points: [.zero, ScenePoint(x: 10, y: 0)])
        let valid = try StrokeGeometryTestSupport.paths([line], style: StrokeGeometryTestSupport.style())
        let curve = try SourcePath(verbs: [.move, .cubic], points: [ScenePoint(x: 20, y: 0),
            ScenePoint(x: 30, y: 20), ScenePoint(x: 10, y: 20), ScenePoint(x: 20, y: 0)])
        let failing = try StrokeGeometryTestSupport.paths([line, curve], style: StrokeGeometryTestSupport.style())
        var cache = try RenderGeometryCache()
        var budget = try GeometryBudget()
        let first = try cache.mesh(for: .shape(valid), transform: .identity, budget: &budget)
        let retainedBytes = cache.byteCount
        for (initial, name) in [(try GeometryBudget(maximumBytes: 1), "maximumRenderGeometryBytes"),
                                (try GeometryBudget(maximumWork: 1), "maximumRenderGeometryWork"),
                                (try GeometryBudget(maximumDepth: 0), "maximumGeometryCurveDepth")] {
            var limited = initial
            #expect(throws: PAGError.resourceLimitExceeded(name)) {
                try cache.mesh(for: .shape(failing), transform: .identity, budget: &limited)
            }
            #expect(cache.count == 1 && cache.byteCount == retainedBytes)
        }
        #expect(try cache.mesh(for: .shape(valid), transform: .identity, budget: &budget) === first)
    }

    /// 完整outline能通过的字节预算，在高精度折线增长时失败；共享入口仍保留已耗工作和旧缓存。
    @Test func finalFlatteningGrowthDoesNotPublishPartialMesh() throws {
        let style = StrokeGeometryTestSupport.style(width: 0.5)
        let geometry = try StrokeGeometryTestSupport.circle(style: style)
        let transform = try SceneAffine.scale(x: 128, y: 128)
        let tolerance = try GeometryPrecision(transform: transform).tolerance * 0.5
        var prefix = try GeometryBudget(maximumBytes: 32_768)
        let centerline = try StrokeCenterline.make(geometry, budget: &prefix)
        let dashed = try StrokeDashing.make(centerline, style: style, budget: &prefix)
        let outline = try StrokeOutline.make(dashed, style: style, tolerance: tolerance, budget: &prefix)
        try #require(!outline.verbs.isEmpty)
        let prefixWork = prefix.work
        // 单独确认失败发生在已完成outline之后，避免测试退化为入口处的bytes=1门禁。
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try PathFlattening.sourcePath(outline, tolerance: tolerance, budget: &prefix)
        }
        #expect(prefix.work > prefixWork)
        var cache = try RenderGeometryCache()
        var normal = try GeometryBudget()
        let old = try cache.mesh(for: .shape(geometry), transform: .identity, budget: &normal)
        let retainedBytes = cache.byteCount
        var limited = try GeometryBudget(maximumBytes: 32_768)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try cache.mesh(for: .shape(geometry), transform: transform, budget: &limited)
        }
        #expect(limited.work > prefixWork)
        #expect(cache.count == 1 && cache.byteCount == retainedBytes)
        #expect(try cache.mesh(for: .shape(geometry), transform: .identity, budget: &normal) === old)
    }

    /// 正但无法均分的最小容差明确失败；空描边不绕过容差校验，纯fill原流程不被此门槛改变。
    @Test func toleranceValidationPrecedesEmptyStrokeFastPaths() throws {
        let stroke = try ShapeGeometry(contours: [], stroke: ShapeStroke(style: StrokeGeometryTestSupport.style(), matrix: .identity))
        var budget = try GeometryBudget()
        for tolerance in [0, -1, Double.infinity, Double.nan] {
            #expect(throws: PAGError.invalidArgument("geometryTolerance")) {
                try PathFlattening.shape(stroke, tolerance: tolerance, budget: &budget)
            }
        }
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try PathFlattening.shape(stroke, tolerance: Double.leastNonzeroMagnitude, budget: &budget)
        }
        let fill = try ShapeGeometry(contours: [])
        #expect(try PathFlattening.shape(fill, tolerance: Double.leastNonzeroMagnitude, budget: &budget).isEmpty)
    }

    /// 已生成旧网格之后取消，后续新描边请求不得继续准备或写缓存；取消沿既有渲染入口传播。
    @Test func cancellationDoesNotReplaceExistingMesh() async throws {
        let geometry = try StrokeGeometryTestSupport.circle(style: StrokeGeometryTestSupport.style(width: 0.5))
        let task = Task {
            var cache = try RenderGeometryCache()
            var budget = try GeometryBudget()
            _ = try cache.mesh(for: .shape(geometry), transform: .identity, budget: &budget)
            let retainedBytes = cache.byteCount
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                return try cache.mesh(for: .shape(geometry), transform: .scale(x: 2, y: 2), budget: &budget)
            } catch {
                #expect(cache.count == 1 && cache.byteCount == retainedBytes)
                throw error
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
