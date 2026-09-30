#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import pag_swift

/// 显式生成器CPU成本探针；分开报告源帧准备、冷网格和warm命中，不把单主机结果当帧率承诺。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PAG_SHAPE_GENERATOR_BENCHMARK"] == "1",
                "设置PAG_SHAPE_GENERATOR_BENCHMARK=1测生成器成本"), .serialized, .timeLimit(.minutes(1)))
struct ShapeGeneratorBenchmarkTests {
    /// 固定大Polygon的颜色帧不得重新展开点；Ellipse尺寸、Star半径/圆度及dash相位单独记录重建成本。
    @Test func recordsColdAndAnimatedPreparationCosts() async throws {
        let ellipse = SourceShape.ellipse(ShapeGeneratorFixtures.ellipse(size: .init(constant: ScenePoint(x: 100, y: 70))))
        let polygon = SourceShape.polyStar(ShapeGeneratorFixtures.polyStar(kind: .polygon, points: .init(constant: 2_048),
            outerRadius: .init(constant: 100)))
        let color = ShapePropertyFixtures.fill(color: try track(.defaultFill, SceneColor(red: 0, green: 0, blue: 255)))
        let sized = SourceShape.ellipse(ShapeGeneratorFixtures.ellipse(size: try track(ScenePoint(x: 100, y: 70), ScenePoint(x: 300, y: 100))))
        let star = SourceShape.polyStar(ShapeGeneratorFixtures.polyStar(points: .init(constant: 5),
            innerRadius: try track(20.0, 40), outerRadius: try track(50.0, 80),
            innerRoundness: try track(0.1, 0.5), outerRoundness: try track(0.1, 0.8)))
        let stroke = try SourceShape.stroke(StrokeFixtures.make(width: .init(constant: 4),
            dashes: SourceDashes(offset: track(0.0, 8), intervals: [.init(constant: 10), .init(constant: 10)])))
        print("PAG generator benchmark os=\(ProcessInfo.processInfo.operatingSystemVersionString) samples=32 byte_limit=67108864 work_limit=16777216")
        try await measure("ellipse_color", [ellipse, color], changesGeometry: false)
        try await measure("polygon_2048_color", [polygon, color], changesGeometry: false)
        try await measure("ellipse_size", [sized, ShapePropertyFixtures.fill()], changesGeometry: true)
        try await measure("star_radii_roundness", [star, ShapePropertyFixtures.fill()], changesGeometry: true)
        try await measure("ellipse_dash_phase", [ellipse, stroke], changesGeometry: true)
    }

    /// 巨大但Int32合法的星形在分配前被默认预算拒绝，不生成截断路径或留存网格。
    @Test func recordsPreallocationRejection() throws {
        let contour = try PolyStarContour.make(ShapeGeneratorFixtures.polyStar(points: .init(constant: 1_000_000)), at: 0, matrix: .identity)
        let geometry = try ShapeGeometry(contours: [.polyStar(contour)])
        var cache = try RenderGeometryCache()
        var budget = try GeometryBudget()
        let start = ContinuousClock.now
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try cache.mesh(for: .shape(geometry), transform: .identity, budget: &budget)
        }
        #expect(cache.count == 0)
        print("PAG generator benchmark star_million_points rejected=maximumRenderGeometryBytes elapsed_ms=\(milliseconds(since: start)) work=\(budget.work) peak_process_rss_bytes=\(try peakRSS())")
    }

    /// 后台工作就绪5ms后请求取消，等待句柄结束并报告实际结果；不伪称取消必落在固定阶段。
    @Test func recordsCancellationResponse() async throws {
        let contour = try PolyStarContour.make(ShapeGeneratorFixtures.polyStar(points: .init(constant: 2_048),
            innerRadius: .init(constant: 80), outerRadius: .init(constant: 100)), at: 0, matrix: .identity)
        let geometry = try ShapeGeometry(contours: [.polyStar(contour)])
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // 独立执行域允许外部请求取消；所有返回路径都等待worker，不能遗留后台成本任务。
        let worker = Task.detached {
            defer { signal.continuation.finish() }
            var cache = try RenderGeometryCache()
            var budget = try GeometryBudget()
            signal.continuation.yield(())
            do {
                _ = try cache.mesh(for: .shape(geometry), transform: .identity, budget: &budget)
                return "finished work=\(budget.work)"
            } catch is CancellationError {
                #expect(cache.count == 0)
                return "cancelled work=\(budget.work)"
            } catch let error as PAGError {
                guard case .resourceLimitExceeded = error else { throw error }
                #expect(cache.count == 0)
                return "rejected=\(error) work=\(budget.work)"
            }
        }
        var iterator = signal.stream.makeAsyncIterator()
        _ = await iterator.next()
        do { try await Task.sleep(for: .milliseconds(5)) }
        catch {
            worker.cancel()
            _ = try? await worker.value
            throw error
        }
        let start = ContinuousClock.now
        worker.cancel()
        let result = try await worker.value
        print("PAG generator benchmark cancellation result=\(result) completion_after_request_ms=\(milliseconds(since: start)) peak_process_rss_bytes=\(try peakRSS())")
    }

    /// 0...64帧线性变化，32个测量帧均处于轨道内部，不把重复尾值当作动画成本。
    private func track<Value: Sendable>(_ start: Value, _ end: Value) throws -> SourceProperty<Value> {
        try SourceProperty(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 64, startValue: start,
            endValue: end, easing: .linear, spatialCurve: nil)])
    }

    /// 首帧冷成本与32个后续帧分开计时，身份断言保证paint命中和真实几何重建都未被跳过。
    private func measure(_ name: String, _ elements: [SourceShape], changesGeometry: Bool) async throws {
        let source = SourceLayerReference(composition: 0, layer: 0)
        let store = try PreparedShapeStore(templates: [source: elements])
        var cache = try RenderGeometryCache()
        let start = ContinuousClock.now
        let first = try await store.sample(ShapeSampleKey(source: source, frame: 0), maximumPreparedBytes: 64 * 1024 * 1024)
        let prepare = milliseconds(since: start)
        var coldBudget = try GeometryBudget()
        let coldStart = ContinuousClock.now
        let cold = try cache.mesh(for: .shape(first.geometries[0]), transform: .identity, budget: &coldBudget)
        let coldMesh = milliseconds(since: coldStart)
        var prepares: [Double] = [], meshes: [Double] = []
        for frame: Int64 in 1...32 {
            let prepareStart = ContinuousClock.now
            let next = try await store.sample(ShapeSampleKey(source: source, frame: frame), maximumPreparedBytes: 64 * 1024 * 1024)
            prepares.append(milliseconds(since: prepareStart))
            var budget = try GeometryBudget()
            let meshStart = ContinuousClock.now
            let mesh = try cache.mesh(for: .shape(next.geometries[0]), transform: .identity, budget: &budget)
            meshes.append(milliseconds(since: meshStart))
            #expect((next.geometries[0] === first.geometries[0]) == (changesGeometry == false))
            #expect((mesh === cold) == (changesGeometry == false))
            if !changesGeometry { #expect(budget.work == 1) }
        }
        print("PAG generator benchmark \(name) cold_prepare_ms=\(prepare) cold_mesh_ms=\(coldMesh) cold_work=\(coldBudget.work) prepare_ms=\(summary(prepares)) mesh_ms=\(summary(meshes)) logical_shape_cache=\(await store.retainedBytes) logical_mesh_cache=\(cache.byteCount) peak_process_rss_bytes=\(try peakRSS())")
    }

    /// 单调时钟只用于诊断，不作为生产降精度或超时依据。
    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }

    /// 固定32个样本的中位数、95分位和最大值，冷调用单独报告。
    private func summary(_ samples: [Double]) -> String {
        let sorted = samples.sorted()
        return "median=\(sorted[16]),p95=\(sorted[30]),max=\(sorted[31])"
    }

    /// 全测试进程累计RSS峰值，不等于本场景净分配，也不等于逻辑预算硬上限。
    private func peakRSS() throws -> Int {
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        return usage.ru_maxrss
    }
}
#endif
