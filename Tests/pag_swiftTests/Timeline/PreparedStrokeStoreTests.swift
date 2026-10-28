import Testing
@testable import pag_swift

/// 四项动态缓存对描边的同源复用、资源边界和失败原子性；不添加公开缓存统计。
struct PreparedStrokeStoreTests {
    /// 同源颜色帧共享几何，其他源即使持有相同路径对象也不能借用；另一个owner同样隔离。
    @Test func reuseIsLimitedToSameSourceAndOwner() async throws {
        let path = try ShapePathFixtures.square(20)
        let source = StrokeFixtures.make(color: try StrokeFixtures.track(StrokeShapeFixtures.color(0), StrokeShapeFixtures.color(100)))
        let elements: [SourceShape] = [.path(.init(constant: path)), .stroke(source)]
        let store = try PreparedShapeStore(templates: [key(0).source: elements, key(0, layer: 1).source: elements])
        let first = try await sample(store, 0)
        let second = try await sample(store, 5)
        let other = try await sample(store, 5, layer: 1)
        #expect(first !== second && first.geometries[0] === second.geometries[0])
        #expect(first.geometries[0] !== other.geometries[0])
        let independent = try PreparedShapeStore(templates: [key(0).source: elements])
        #expect(try await sample(independent, 5).geometries[0] !== first.geometries[0])
    }

    /// 只有现存四项可以借用几何，几何变化的旧帧被淘汰后重建；禁用缓存完全不保留候选。
    @Test func evictionAndDisabledCacheHaveNoHiddenHistory() async throws {
        let source = StrokeFixtures.make(width: try StrokeFixtures.track(1.0, 11))
        let elements: [SourceShape] = [StrokeShapeFixtures.rectangle(), .stroke(source)]
        let store = try PreparedShapeStore(templates: [key(0).source: elements])
        let old = try await sample(store, 0)
        for frame: Int64 in [2, 4, 6, 8] { _ = try await sample(store, frame) }
        let rebuilt = try await sample(store, 0)
        #expect(rebuilt !== old && rebuilt.geometries[0] !== old.geometries[0])
        let disabled = try PreparedShapeStore(templates: [key(0).source: elements], maximumBytes: 0)
        let first = try await sample(disabled, 0)
        let second = try await sample(disabled, 0)
        #expect(first.geometries[0] !== second.geometries[0])
        #expect(await disabled.retainedBytes == 0)
    }

    /// 失败的命中、失败的新帧和取消均不刷新LRU，随后第五帧仍淘汰原先最旧项。
    @Test func failedRequestsLeaveAccessOrderAndRetainedBytesUntouched() async throws {
        let source = StrokeFixtures.make(width: try StrokeFixtures.track(1.0, 11))
        let elements: [SourceShape] = [StrokeShapeFixtures.rectangle(), .stroke(source)]
        let store = try PreparedShapeStore(templates: [key(0).source: elements])
        let first = try await sample(store, 0)
        let second = try await sample(store, 1)
        _ = try await sample(store, 2)
        _ = try await sample(store, 3)
        let bytes = await store.retainedBytes
        for frame: Int64 in [0, 4] {
            await #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
                try await store.sample(key(frame), maximumPreparedBytes: first.estimatedBytes - 1)
            }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await sample(store, 0)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await store.retainedBytes == bytes)
        _ = try await sample(store, 4)
        #expect(try await sample(store, 1) === second)
        #expect(try await sample(store, 0) !== first)
        #expect(first.geometries[0].stroke?.style.width == 1)
    }

    /// 最近宽度不同的帧不能遮挡更早匹配；只有颜色变化的请求仍接受新调用的保活限额。
    @Test func candidatesSearchNewestCompatibleGeometryWithinBudget() async throws {
        let width = try StrokeFixtures.track(2.0, 4, easing: .hold)
        let source = StrokeFixtures.make(width: width,
            color: try StrokeFixtures.track(StrokeShapeFixtures.color(0), StrokeShapeFixtures.color(100)))
        let elements: [SourceShape] = [StrokeShapeFixtures.rectangle(), .stroke(source)]
        let store = try PreparedShapeStore(templates: [key(0).source: elements])
        let first = try await sample(store, 0)
        let changed = try await sample(store, 10)
        let middle = try await sample(store, 5)
        #expect(first.geometries[0] !== changed.geometries[0])
        #expect(middle.geometries[0] === first.geometries[0])
        let bytes = await store.retainedBytes
        await #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try await store.sample(key(6), maximumPreparedBytes: first.estimatedBytes - 1)
        }
        #expect(await store.retainedBytes == bytes)
    }

    /// 在固定源层与指定帧取完整结果，每次调用都有独立帧预算。
    private func sample(_ store: PreparedShapeStore, _ frame: Int64, layer: Int = 0) async throws -> PreparedShapeLayer {
        try await store.sample(key(frame, layer: layer), maximumPreparedBytes: 1_000_000)
    }

    /// 同一文档内的源引用；layer变化表示另一个源，不能根据内容相等合并。
    private func key(_ frame: Int64, layer: Int = 0) -> ShapeSampleKey {
        ShapeSampleKey(source: SourceLayerReference(composition: 0, layer: layer), frame: frame)
    }
}
