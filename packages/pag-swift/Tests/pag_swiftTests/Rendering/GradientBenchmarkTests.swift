#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import pag_swift

/// 显式渐变CPU成本探针；播放帧率、GPU吞吐和内存净增长不由本组数据推断。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PAG_GRADIENT_BENCHMARK"] == "1",
                "设置PAG_GRADIENT_BENCHMARK=1测渐变成本"), .serialized, .timeLimit(.minutes(1)))
struct GradientBenchmarkTests {
    /// 静态、颜色与端点动画分别测32帧；最大八段及4096项退化场景仍须保留缓存身份。
    @Test func recordsStaticAndAnimatedCosts() async throws {
        print("PAG gradient benchmark os=\(ProcessInfo.processInfo.operatingSystemVersionString) samples=32 byte_limit=67108864")
        for (name, count, mode): (String, Int, GradientBenchmarkMode) in [
            ("static_2", 2, .staticMaterial), ("static_8_intervals", 9, .staticMaterial),
            ("color_2", 2, .color), ("color_8_intervals", 9, .color),
            ("endpoint_2", 2, .endpoint), ("endpoint_8_intervals", 9, .endpoint),
            ("endpoint_4096_degenerate", 4096, .degenerateEndpoint)
        ] {
            try await measure(name, source: source(count: count, mode: mode), mode: mode)
        }
    }

    /// 超解析容量且不退化时固定输入明确拒绝；同一source的退化帧仍成功，不能把缓存状态误当布局结果。
    @Test func recordsAnalyticCapacityRejection() throws {
        let values = colors(count: 20)
        var sourceBudget = FramePlanBudget(limit: 64 * 1024 * 1024)
        let gradient = try GradientEvaluation.prepare(GradientShapeFixtures.gradient(colors: .init(constant: values)),
            at: 0, matrix: .identity, reusing: [], budget: &sourceBudget)
        var budget = try MetalFrameBudget()
        var rejection: PAGError?
        let start = ContinuousClock.now
        // 测试宏的诊断和错误匹配不计入生产拒绝路径的CPU时间。
        do { _ = try MetalGradientInput.make(gradient, origin: .zero, budget: &budget) }
        catch let error as PAGError { rejection = error }
        let elapsed = milliseconds(since: start)
        #expect(rejection == .unsupportedFeature("gradientTextureColorizer"))
        let degenerate = PreparedGradient(kind: gradient.kind, start: gradient.start, end: gradient.start,
            matrix: gradient.matrix, colorizer: gradient.colorizer, estimatedBytes: gradient.estimatedBytes)
        guard case .solid = try MetalGradientInput.make(degenerate, origin: .zero, budget: &budget) else {
            Issue.record("容量拒绝不能抢在几何退化之前"); return
        }
        print("PAG gradient benchmark stops_20 rejected=gradientTextureColorizer input_cpu_ms=\(elapsed) retained_program_bytes=\(gradient.colorizer.estimatedBytes) peak_process_rss_bytes=\(try peakRSS())")
    }

    /// worker启动信号后5ms请求取消；记录实际完成结果并等待worker，不伪称固定阶段被中断。
    @Test func recordsCancellationResponse() async throws {
        let gradient = try source(count: 4096, mode: .color)
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // 单个独立CPU域便于外部取消，所有退出路径都等待worker结束，不遗留成本任务。
        let worker = Task.detached {
            defer { signal.continuation.finish() }
            signal.continuation.yield(())
            var completed = 0
            do {
                for index in 1...128 {
                    var budget = FramePlanBudget(limit: 64 * 1024 * 1024)
                    _ = try GradientEvaluation.prepare(gradient, at: Int64(index % 63 + 1), matrix: .identity,
                                                       reusing: [], budget: &budget)
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
        print("PAG gradient benchmark cancellation result=\(result) completion_after_request_ms=\(milliseconds(since: start)) peak_process_rss_bytes=\(try peakRSS())")
    }

    /// 使用原有四候选owner与CPU网格缓存；常量按同帧命中，动画32帧均位于轨道内部。
    private func measure(_ name: String, source: SourceGradient, mode: GradientBenchmarkMode) async throws {
        let reference = SourceLayerReference(composition: 0, layer: 0)
        let store = try PreparedShapeStore(templates: [reference: GradientShapeFixtures.elements(source)])
        var cache = try RenderGeometryCache()
        let start = ContinuousClock.now
        let first = try await store.sample(.init(source: reference, frame: 0), maximumPreparedBytes: 64 * 1024 * 1024)
        let coldPrepare = milliseconds(since: start)
        let original = try #require(first.gradientColorizersByPaint[0])
        var meshBudget = try GeometryBudget()
        let meshStart = ContinuousClock.now
        let mesh = try cache.mesh(for: .shape(first.geometries[0]), transform: .identity, budget: &meshBudget)
        let coldMesh = milliseconds(since: meshStart)
        var prepares: [Double] = [], meshes: [Double] = [], inputs: [Double] = []
        for index: Int64 in 1...32 {
            let frame: Int64 = mode == .staticMaterial ? 0 : index
            let prepareStart = ContinuousClock.now
            let next = try await store.sample(.init(source: reference, frame: frame), maximumPreparedBytes: 64 * 1024 * 1024)
            prepares.append(milliseconds(since: prepareStart))
            let paint = try #require(ShapePropertyFixtures.paints(next).first)
            let material = try paint.material.gradientValue()
            #expect((material.colorizer === original) == (mode != .color))
            #expect(next.geometries[0] === first.geometries[0])
            if mode == .staticMaterial { #expect(next === first) }
            var geometryBudget = try GeometryBudget()
            let warmStart = ContinuousClock.now
            let reused = try cache.mesh(for: .shape(next.geometries[0]), transform: .identity, budget: &geometryBudget)
            meshes.append(milliseconds(since: warmStart))
            #expect(reused === mesh && geometryBudget.work == 1)
            var inputBudget = try MetalFrameBudget()
            let inputStart = ContinuousClock.now
            let input = try MetalGradientInput.make(material, origin: .zero, budget: &inputBudget)
            inputs.append(milliseconds(since: inputStart))
            switch input {
            case .solid: #expect(mode == .degenerateEndpoint)
            case .analytic(let value):
                #expect(mode != .degenerateEndpoint)
                if original.source.colorStops.count == 9 { #expect(value.header.z == 8) }
            }
        }
        print("PAG gradient benchmark \(name) cold_prepare_ms=\(coldPrepare) cold_mesh_ms=\(coldMesh) prepare_ms=\(summary(prepares)) warm_mesh_ms=\(summary(meshes)) input_cpu_ms=\(summary(inputs)) logical_shape_cache=\(await store.retainedBytes) logical_mesh_cache=\(cache.byteCount) peak_process_rss_bytes=\(try peakRSS())")
    }

    /// 颜色与端点各自独立变化；大表端点同步平移保持退化，检验warm路径不重扫源stop。
    private func source(count: Int, mode: GradientBenchmarkMode) throws -> SourceGradient {
        let values = colors(count: count)
        let colorTrack = try mode == .color ? track(values, colors(count: count, shifted: true)) : SourceProperty(constant: values)
        let start = try mode == .degenerateEndpoint ? track(ScenePoint.zero, ScenePoint(x: 40, y: 20)) : .init(constant: .zero)
        let end: SourceProperty<ScenePoint>
        if mode == .degenerateEndpoint { end = start }
        else if mode == .endpoint { end = try track(ScenePoint(x: 100, y: 0), ScenePoint(x: 200, y: 60)) }
        else { end = .init(constant: ScenePoint(x: 100, y: 0)) }
        return GradientShapeFixtures.gradient(start: start, end: end, colors: colorTrack)
    }

    /// 全部位置严格升序，九色恰为八区间；交错颜色避免程序被误当成单色优化。
    private func colors(count: Int, shifted: Bool = false) -> SourceGradientColors {
        let stops: [(Float, SceneColor)] = (0..<count).map { (index: Int) in
            let amount = UInt8(index % 2 == 0 ? 0 : 255)
            let color = shifted ? SceneColor(red: 0, green: amount, blue: 255 - amount)
                                : SceneColor(red: amount, green: 0, blue: 255 - amount)
            return (Float(index) / Float(count - 1), color)
        }
        return GradientColorFixtures.colors(rgb: stops)
    }

    /// 0...64帧轨道避免32次采样提前落到静态尾端。
    private func track<Value: Sendable>(_ start: Value, _ end: Value) throws -> SourceProperty<Value> {
        try SourceProperty(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 64, startValue: start,
            endValue: end, easing: .linear, spatialCurve: nil)])
    }

    /// 单调时钟只记录成本，不参与运行时降精度或超时策略。
    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }

    /// 32个样本分别报告中位、95分位与最大值，不混入冷准备。
    private func summary(_ samples: [Double]) -> String {
        let sorted = samples.sorted()
        return "median=\(sorted[16]),p95=\(sorted[30]),max=\(sorted[31])"
    }

    /// 这是整个测试进程的累计峰值，不是材料净分配或缓存逻辑预算。
    private func peakRSS() throws -> Int {
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        return usage.ru_maxrss
    }
}

/// 成本场景的采样方式，只供本文件控制身份断言和计时，不进入生产播放模型。
private enum GradientBenchmarkMode {
    /// 同源同帧命中完整静态样本。
    case staticMaterial
    /// 每帧插值颜色，新程序与旧几何并存。
    case color
    /// 每帧改变布局端点，保留颜色程序。
    case endpoint
    /// 两端同步变化并重合，超解析容量仍可走退化纯色。
    case degenerateEndpoint
}
#endif
