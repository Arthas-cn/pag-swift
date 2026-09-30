#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import pag_swift

/// 显式启用的描边CPU成本探针；记录当前主机观测，不将耗时或进程RSS误作跨设备保证。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PAG_STROKE_BENCHMARK"] == "1",
                "设置PAG_STROKE_BENCHMARK=1运行描边成本与取消探针"), .serialized, .timeLimit(.minutes(1)))
struct StrokePlaybackBenchmarkTests {
    /// 在共同网格冷路径测Line链、短dash、高曲率和真实宽度端值；资源拒绝也必须报告，不能发前缀网格。
    @Test func recordsBoundedColdGeometryAndWarmMeshes() throws {
        print("PAG stroke benchmark os=\(ProcessInfo.processInfo.operatingSystemVersionString) logical_byte_limit=67108864 work_limit=16777216")
        for count in [128, 512, 2_048, 8_192, 16_384] {
            let geometry = try StrokeGeometryTestSupport.paths([lineChain(count)], style: StrokeGeometryTestSupport.style())
            try measure("line_\(count)", geometry: geometry)
        }
        let pattern = try #require(try StrokeDashPattern.make(intervals: [0.5, 0.5], phase: 0))
        for length in [100, 1_000, 10_000, 100_000] {
            let path = try SourcePath(verbs: [.move, .line], points: [.zero, ScenePoint(x: Double(length), y: 0)])
            let geometry = try StrokeGeometryTestSupport.paths([path], style: StrokeGeometryTestSupport.style(cap: .round, dashes: pattern))
            try measure("dash_\(length)", geometry: geometry)
        }
        for count in [4, 32, 128] {
            let geometry = try StrokeGeometryTestSupport.paths([curves(count)], style: StrokeGeometryTestSupport.style(cap: .round, join: .round))
            try measure("curves_\(count)", geometry: geometry)
        }
        // 大部分投影确实重叠，不能被轴筛选消掉；单独观察默认上限下仍然存在的最坏冷成本。
        let dense = try StrokeGeometryTestSupport.paths([denseCrossings(1_024)], style: StrokeGeometryTestSupport.style(join: .bevel))
        try measure("dense_crossing_1024", geometry: dense)
        // 真实载荷只提供样式；路径为成本夹具，不冒充这些文件的完整可播放场景。
        for (name, range, frame) in [("PAG_LOGO.pag", 10252..<10312, Int64(250)), ("0.pag", 204..<213, Int64(0))] {
            let source = try StrokeFixtures.source(named: name, range: range)
            let value = try #require(try StrokeEvaluation.evaluate(source, at: frame))
            let geometry = try StrokeGeometryTestSupport.paths([curves(8)], style: value.style)
            try measure("real_style_\(name)_width_\(value.style.width)_miter_\(value.style.miterLimit)", geometry: geometry)
        }
        let limited = try StrokeGeometryTestSupport.paths([curves(32)], style: StrokeGeometryTestSupport.style())
        try measure("curves_32_bytes_32768", geometry: limited, maximumBytes: 32_768)
        try measure("curves_32_work_1024", geometry: limited, maximumWork: 1_024)
    }

    /// 颜色帧只测prepare，网格warm由前一用例单独测量；宽度动画另计prepare+mesh，不掩盖逐点检查。
    @Test func recordsColorPreparationAndGeometryAnimation() async throws {
        let reference = SourceLayerReference(composition: 0, layer: 0)
        for count in [128, 8_192] {
            let path = try lineChain(count)
            let source = StrokeFixtures.make(color: try StrokeFixtures.track(StrokeShapeFixtures.color(0), StrokeShapeFixtures.color(255), end: 100))
            let elements: [SourceShape] = [.path(.init(constant: path)), .stroke(source)]
            let store = try PreparedShapeStore(templates: [reference: elements])
            let first = try await store.sample(ShapeSampleKey(source: reference, frame: 0), maximumPreparedBytes: 64 * 1024 * 1024)
            var durations: [Double] = []
            for frame: Int64 in 1...32 {
                let start = ContinuousClock.now
                let next = try await store.sample(ShapeSampleKey(source: reference, frame: frame), maximumPreparedBytes: 64 * 1024 * 1024)
                durations.append(milliseconds(since: start))
                #expect(next.geometries[0] === first.geometries[0])
            }
            print("PAG stroke benchmark color_path_\(count)_prepare_only ms=\(summary(durations)) logical_first=\(first.estimatedBytes) logical_cache=\(await store.retainedBytes) peak_process_rss_bytes=\(try peakRSS())")
        }
        let source = StrokeFixtures.make(width: try StrokeFixtures.track(1.0, 5, end: 32))
        let elements: [SourceShape] = [.path(.init(constant: try lineChain(128))), .stroke(source)]
        let store = try PreparedShapeStore(templates: [reference: elements])
        var cache = try RenderGeometryCache()
        var durations: [Double] = []
        var previous: ShapeGeometry?
        for frame: Int64 in 0..<8 {
            let start = ContinuousClock.now
            let next = try await store.sample(ShapeSampleKey(source: reference, frame: frame), maximumPreparedBytes: 64 * 1024 * 1024)
            var budget = try GeometryBudget()
            _ = try cache.mesh(for: .shape(next.geometries[0]), transform: .identity, budget: &budget)
            durations.append(milliseconds(since: start))
            #expect(next.geometries[0] !== previous)
            previous = next.geometries[0]
        }
        print("PAG stroke benchmark animated_width_128_prepare_plus_mesh ms=\(summary(durations)) meshes=\(cache.count) logical_mesh_cache=\(cache.byteCount) peak_process_rss_bytes=\(try peakRSS())")
    }

    /// 工作线程准备就绪5ms后请求取消并等待清理；记录实际work，不保证取消落在固定几何阶段。
    @Test func recordsCancellationResponse() async throws {
        let geometry = try StrokeGeometryTestSupport.paths([lineChain(8_192)], style: StrokeGeometryTestSupport.style())
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // 独立任务用于从另一执行器发送真实取消，句柄在本测试内必定cancel并等待，不留下后台工作。
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
                return "finished_with_error=\(error) work=\(budget.work)"
            }
        }
        var iterator = signal.stream.makeAsyncIterator()
        _ = await iterator.next()
        do {
            try await Task.sleep(for: .milliseconds(5))
        } catch {
            worker.cancel()
            _ = try? await worker.value
            throw error
        }
        let cancellation = ContinuousClock.now
        worker.cancel()
        let result = try await worker.value
        print("PAG stroke benchmark cancellation result=\(result) completion_after_request_ms=\(milliseconds(since: cancellation)) peak_process_rss_bytes=\(try peakRSS())")
    }

    /// 一条有轻微接角的长折线，长度和指令数独立可控，不借助生产几何生成输入。
    private func lineChain(_ count: Int) throws -> SourcePath {
        try SourcePath(verbs: [.move] + Array(repeating: .line, count: count), points: (0...count).map {
            ScenePoint(x: Double($0) * 2, y: $0.isMultiple(of: 2) ? 0 : 0.5)
        })
    }

    /// 连续高曲率Cubic成本输入；每段左右相连，不把它分成独立端帽来简化准备。
    private func curves(_ count: Int) throws -> SourcePath {
        var points: [ScenePoint] = [.zero]
        for index in 0..<count {
            let x = Double(index) * 10
            points += [ScenePoint(x: x + 4, y: 8), ScenePoint(x: x + 6, y: -8), ScenePoint(x: x + 10, y: 0)]
        }
        return try SourcePath(verbs: [.move] + Array(repeating: .cubic, count: count), points: points)
    }

    /// 左右交替的长线制造密集真实交叉，另一侧的细小有理偏移避免所有边只在一个中心点相交。
    private func denseCrossings(_ count: Int) throws -> SourcePath {
        let points = (0...count).map { index in
            let row = Double(index / 2)
            return ScenePoint(x: index.isMultiple(of: 2) ? 0 : 1_024,
                y: index.isMultiple(of: 2) ? row : Double(count / 2) - row + Double((index / 2) % 7) / 32)
        }
        return try SourcePath(verbs: [.move] + Array(repeating: .line, count: count), points: points)
    }

    /// 完整cold请求成功才测16次warm命中；资源拒绝打印错误、已耗work和零缓存，不降精度重试。
    private func measure(_ name: String, geometry: ShapeGeometry, maximumBytes: Int = 64 * 1024 * 1024,
                         maximumWork: Int = 16_777_216) throws {
        var cache = try RenderGeometryCache()
        var budget = try GeometryBudget(maximumBytes: maximumBytes, maximumWork: maximumWork)
        let start = ContinuousClock.now
        do {
            let first = try cache.mesh(for: .shape(geometry), transform: .identity, budget: &budget)
            let elapsed = milliseconds(since: start)
            var warm: [Double] = []
            for _ in 0..<16 {
                var hit = try GeometryBudget(maximumWork: 1)
                let start = ContinuousClock.now
                let next = try cache.mesh(for: .shape(geometry), transform: .identity, budget: &hit)
                warm.append(milliseconds(since: start))
                #expect(next === first && hit.work == 1)
            }
            print("PAG stroke benchmark \(name) cold_ms=\(elapsed) work=\(budget.work) vertices=\(first.vertices.count) logical_mesh_cache=\(cache.byteCount) warm_ms=\(summary(warm)) peak_process_rss_bytes=\(try peakRSS())")
        } catch let error as PAGError {
            guard case .resourceLimitExceeded = error else { throw error }
            #expect(cache.count == 0)
            print("PAG stroke benchmark \(name) rejected=\(error) elapsed_ms=\(milliseconds(since: start)) work=\(budget.work) peak_process_rss_bytes=\(try peakRSS())")
        }
    }

    /// 用单调时钟测实际经过时间，转换只用于报告，不参与生产超时或错误分类。
    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }

    /// 固定非空样本的中位数、95分位和最大值；不让一次暖机或冷调用混入同一个分布。
    private func summary(_ values: [Double]) -> String {
        let sorted = values.sorted()
        return "median=\(sorted[sorted.count / 2]),p95=\(sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1]),max=\(sorted.last!)"
    }

    /// Darwin getrusage手册定义ru_maxrss为字节；这是整个测试进程的累计峰值，不能归因成当前调用净分配。
    private func peakRSS() throws -> Int {
        var value = rusage()
        try #require(getrusage(RUSAGE_SELF, &value) == 0)
        return value.ru_maxrss
    }
}
#endif
