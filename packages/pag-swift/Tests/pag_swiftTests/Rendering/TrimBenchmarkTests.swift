#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import pag_swift

/// 显式Trim成本探针；报告CPU准备和保活，不把结果解释为GPU吞吐、播放帧率或净内存增长。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PAG_TRIM_BENCHMARK"] == "1",
                "设置PAG_TRIM_BENCHMARK=1测裁剪成本"), .serialized, .timeLimit(.minutes(1)))
struct TrimBenchmarkTests {
    /// 两档路径分别测静态、颜色动画和范围动画，记录冷/暖准备及网格，不混入测试断言耗时。
    @Test func recordsStaticColorAndRangeCosts() async throws {
        print("PAG trim benchmark os=\(ProcessInfo.processInfo.operatingSystemVersionString) samples=32 byte_limit=67108864")
        for count in [32, 256] {
            for mode in [TrimBenchmarkMode.staticPath, .color, .range] {
                try await measure(count: count, mode: mode)
            }
        }
    }

    /// 缓存命中仍扣整份保活成本；不足时失败且保持原样本，不把拒绝时间混成正常命中时间。
    @Test func recordsRetentionBudgetRejection() async throws {
        let reference = SourceLayerReference(composition: 0, layer: 0)
        let key = ShapeSampleKey(source: reference, frame: 0)
        let store = try PreparedShapeStore(templates: [reference: source(count: 256, mode: .range)])
        let first = try await store.sample(key, maximumPreparedBytes: 64 * 1024 * 1024)
        let before = await store.retainedBytes
        var rejected: PAGError?
        let start = ContinuousClock.now
        do { _ = try await store.sample(key, maximumPreparedBytes: first.estimatedBytes - 1) }
        catch let error as PAGError { rejected = error }
        let elapsed = milliseconds(since: start)
        #expect(rejected == .resourceLimitExceeded("maximumFramePlanBytes"))
        #expect(await store.retainedBytes == before)
        #expect(try await store.sample(key, maximumPreparedBytes: 64 * 1024 * 1024) === first)
        print("PAG trim benchmark budget rejected=maximumFramePlanBytes input_cpu_ms=\(elapsed) retained_shape_bytes=\(before) peak_process_rss_bytes=\(try peakRSS())")
    }

    /// worker开始后5ms请求取消并等结束，报告实际完成样本数，不声称在某个曲线细分点强制中断。
    @Test func recordsCancellationResponse() async throws {
        let elements = try source(count: 4096, mode: .range)
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let worker = Task.detached {
            defer { signal.continuation.finish() }
            signal.continuation.yield(())
            var completed = 0
            do {
                for index in 1...128 {
                    var budget = FramePlanBudget(limit: 64 * 1024 * 1024)
                    _ = try ShapePreparation.prepare(elements, at: Int64(index % 63 + 1), budget: &budget)
                    completed += 1
                }
                return "finished samples=\(completed)"
            } catch is CancellationError { return "cancelled samples=\(completed)" }
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
        print("PAG trim benchmark cancellation result=\(result) completion_after_request_ms=\(milliseconds(since: start)) peak_process_rss_bytes=\(try peakRSS())")
    }

    /// 使用四候选store与生产CPU网格缓存，32个动画采样均处于轨道内部，旧输出显式保活。
    private func measure(count: Int, mode: TrimBenchmarkMode) async throws {
        let reference = SourceLayerReference(composition: 0, layer: 0)
        let store = try PreparedShapeStore(templates: [reference: source(count: count, mode: mode)])
        var cache = try RenderGeometryCache()
        let start = ContinuousClock.now
        let first = try await store.sample(.init(source: reference, frame: 0), maximumPreparedBytes: 64 * 1024 * 1024)
        let coldPrepare = milliseconds(since: start)
        let original = try #require(first.trimBatchesByModifier[0])
        var coldBudget = try GeometryBudget()
        let meshStart = ContinuousClock.now
        let mesh = try cache.mesh(for: .shape(first.geometries[0]), transform: .identity, budget: &coldBudget)
        let coldMesh = milliseconds(since: meshStart)
        var prepares: [Double] = [], meshes: [Double] = []
        var lastBatch = original
        for index: Int64 in 1...32 {
            let begin = ContinuousClock.now
            let next = try await store.sample(.init(source: reference, frame: mode == .staticPath ? 0 : index),
                                               maximumPreparedBytes: 64 * 1024 * 1024)
            prepares.append(milliseconds(since: begin))
            let batch = try #require(next.trimBatchesByModifier[0])
            #expect((batch === original) == (mode != .range))
            #expect(sharesMeasurements(original, batch))
            #expect((next.geometries[0] === first.geometries[0]) == (mode != .range))
            if mode == .staticPath { #expect(next === first) }
            var budget = try GeometryBudget()
            let meshBegin = ContinuousClock.now
            let nextMesh = try cache.mesh(for: .shape(next.geometries[0]), transform: .identity, budget: &budget)
            meshes.append(milliseconds(since: meshBegin))
            #expect((nextMesh === mesh) == (mode != .range))
            if mode != .range { #expect(budget.work == 1) }
            lastBatch = batch
        }
        let measurement = try #require(lastBatch.measurements?.first)
        let table = try #require(measurement.measure)
        var retained = FramePlanBudget(limit: Int.max)
        try retained.reserve(stride: 256)
        try PreparedTrimPath.retain(measurement.path, budget: &retained)
        try retained.reserve(count: table.curves.count, stride: 128)
        try retained.reserve(count: table.records.count, stride: 32)
        let outputs = lastBatch.outputs.reduce(0) { $0 + 192 + $1.referencedBytes }
        print("PAG trim benchmark count=\(count) mode=\(mode.rawValue) cold_prepare_ms=\(coldPrepare) cold_mesh_ms=\(coldMesh) prepare_ms=\(summary(prepares)) mesh_ms=\(summary(meshes)) batch_bytes=\(lastBatch.estimatedBytes) measurement_bytes=\(retained.used) output_bytes=\(outputs) logical_shape_cache=\(await store.retainedBytes) logical_mesh_cache=\(cache.byteCount) peak_process_rss_bytes=\(try peakRSS())")
    }

    /// 比较仍存活测量数组的存储地址；仅在同步借用内比较，不让裸指针逃逸或跨隔离。
    private func sharesMeasurements(_ first: PreparedTrimBatch, _ second: PreparedTrimBatch) -> Bool {
        guard let lhs = first.measurements?.first?.measure, let rhs = second.measurements?.first?.measure else { return false }
        return lhs.records.withUnsafeBufferPointer { a in rhs.records.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress } }
            && lhs.curves.withUnsafeBufferPointer { a in rhs.curves.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress } }
    }

    /// 单调x的折线带在底部闭合，路径不会靠自交扩大成本；计数是上缘线段数而非文件字节上限。
    private func source(count: Int, mode: TrimBenchmarkMode) throws -> [SourceShape] {
        var points = (0...count).map { ScenePoint(x: Double($0) * 100 / Double(count), y: $0 % 2 == 0 ? 20 : 30) }
        points += [ScenePoint(x: 100, y: 10), ScenePoint(x: 0, y: 10)]
        let path = try SourcePath(verbs: [.move] + Array(repeating: .line, count: count + 2) + [.close], points: points)
        let range = try mode == .range ? track(0.5, 0.9) : SourceProperty(constant: 0.5)
        let color = try mode == .color ? track(SceneColor.defaultFill, SceneColor(red: 0, green: 0, blue: 255)) : .init(constant: .defaultFill)
        return [.path(.init(constant: path)), .trimPaths(SourceTrimPaths(start: .init(constant: 0), end: range,
            offset: .init(constant: 0), mode: .simultaneously)), ShapePropertyFixtures.fill(color: color)]
    }

    /// 0...64帧轨道，32次采样不会提前退化为恒定尾值。
    private func track<Value: Sendable>(_ start: Value, _ end: Value) throws -> SourceProperty<Value> {
        try SourceProperty(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 64, startValue: start,
            endValue: end, easing: .linear, spatialCurve: nil)])
    }

    /// 单调时钟只用于测量，不改变生产精度、重试或取消政策。
    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }

    /// 固定32样本报告中位/95分位/最大值，不混入冷启动时间。
    private func summary(_ samples: [Double]) -> String {
        let sorted = samples.sorted()
        return "median=\(sorted[16]),p95=\(sorted[30]),max=\(sorted[31])"
    }

    /// 整个测试进程的累计峰值RSS，不能与逻辑缓存字节相减解释为净分配。
    private func peakRSS() throws -> Int {
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        return usage.ru_maxrss
    }
}

/// 成本场景只控制测试采样与断言，不扩展生产播放API。
private enum TrimBenchmarkMode: String {
    /// 同源同帧命中完整静态样本。
    case staticPath
    /// paint颜色变化，裁剪输出和测量及网格均可复用。
    case color
    /// 裁剪范围逐帧变化，只复用测量，输出和网格各自更新。
    case range
}
#endif
