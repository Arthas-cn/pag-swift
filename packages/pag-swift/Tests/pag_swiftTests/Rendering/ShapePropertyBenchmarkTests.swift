#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import pag_swift

/// 显式形状属性CPU成本探针；测共同准备与网格缓存，不把单主机结果承诺为所有文件60fps。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PAG_SHAPE_PROPERTY_BENCHMARK"] == "1",
                "设置PAG_SHAPE_PROPERTY_BENCHMARK=1测形状属性成本"), .serialized, .timeLimit(.minutes(1)))
struct ShapePropertyBenchmarkTests {
    /// 长静态路径的颜色/alpha只改paint；组移动与矩形尺寸动画必须实际重建几何和网格。
    @Test func recordsPreparationAndMeshCosts() async throws {
        let large = try perimeter(sideSegments: 2_048)
        let smaller = try perimeter(sideSegments: 128)
        let color = ShapePropertyFixtures.fill(color: try track(SceneColor(red: 0, green: 0, blue: 255), .defaultFill))
        let opacity = ShapePropertyFixtures.fill(opacity: try track(UInt8(64), UInt8(255)))
        let translation = ShapePropertyFixtures.group(position: try track(.zero, ScenePoint(x: 10, y: 20)))
        let rectangle = ShapePropertyFixtures.rectangle(size: try track(ScenePoint(x: 20, y: 20), ScenePoint(x: 40, y: 40)),
            roundness: try track(0.0, 8))
        print("PAG shape property benchmark os=\(ProcessInfo.processInfo.operatingSystemVersionString) samples=32 byte_limit=67108864")
        try await measure("color_path_8192", [.path(.init(constant: large)), color], changesGeometry: false)
        try await measure("opacity_path_8192", [.path(.init(constant: large)), opacity], changesGeometry: false)
        try await measure("group_position_path_512", [.group(translation,
            [.path(.init(constant: smaller)), ShapePropertyFixtures.fill()])], changesGeometry: true)
        try await measure("rectangle_size_roundness", [rectangle, ShapePropertyFixtures.fill()], changesGeometry: true)
    }

    /// 沿矩形四边均匀细分出指定点数，输入拓扑固定且无密集交叉，避免把属性成本与恶意几何混在一起。
    private func perimeter(sideSegments: Int) throws -> SourcePath {
        var points: [ScenePoint] = []
        for index in 0..<sideSegments {
            points.append(ScenePoint(x: Double(index) / Double(sideSegments) * 100, y: 0))
        }
        for index in 0..<sideSegments {
            points.append(ScenePoint(x: 100, y: Double(index) / Double(sideSegments) * 100))
        }
        for index in 0..<sideSegments {
            points.append(ScenePoint(x: 100 - Double(index) / Double(sideSegments) * 100, y: 100))
        }
        for index in 0..<sideSegments {
            points.append(ScenePoint(x: 0, y: 100 - Double(index) / Double(sideSegments) * 100))
        }
        return try SourcePath(verbs: [.move] + Array(repeating: .line, count: points.count - 1) + [.close], points: points)
    }

    /// 0...64帧线性变化，测量窗口内每个帧值都实际不同，不误把尾值重复当动画成本。
    private func track<Value: Sendable>(_ start: Value, _ end: Value) throws -> SourceProperty<Value> {
        try SourceProperty(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 64, startValue: start,
            endValue: end, easing: .linear, spatialCurve: nil)])
    }

    /// 首帧冷成本独立记录，随后32帧拆分prepare与mesh计时；缓存身份断言保证测试没有绕过应做工作。
    private func measure(_ name: String, _ elements: [SourceShape], changesGeometry: Bool) async throws {
        let source = SourceLayerReference(composition: 0, layer: 0)
        let store = try PreparedShapeStore(templates: [source: elements])
        var cache = try RenderGeometryCache()
        let start = ContinuousClock.now
        let first = try await store.sample(ShapeSampleKey(source: source, frame: 0), maximumPreparedBytes: 64 * 1024 * 1024)
        let preparation = milliseconds(since: start)
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
        print("PAG shape property benchmark \(name) cold_prepare_ms=\(preparation) cold_mesh_ms=\(coldMesh) prepare_ms=\(summary(prepares)) mesh_ms=\(summary(meshes)) logical_shape_cache=\(await store.retainedBytes) logical_mesh_cache=\(cache.byteCount) peak_process_rss_bytes=\(try peakRSS())")
    }

    /// 单调时间转换为毫秒，仅用于报告，不进入生产超时或回退策略。
    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }

    /// 32个真实样本的中位数、95分位和最大值，首帧冷成本不混入该分布。
    private func summary(_ samples: [Double]) -> String {
        let sorted = samples.sorted()
        return "median=\(sorted[16]),p95=\(sorted[30]),max=\(sorted[31])"
    }

    /// 整个测试进程的累计峰值；不能把该数当作当前调用净分配或逻辑预算硬上限。
    private func peakRSS() throws -> Int {
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        return usage.ru_maxrss
    }
}
#endif
