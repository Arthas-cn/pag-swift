import Testing
@testable import pag_swift

/// 动态形状缓存的同源四帧、全局64条、逻辑字节与失败原子性；不缓存整屏图像。
struct PreparedShapeStoreTests {
    /// 真实慢素材含多个动态源层；重复同一根帧应复用全部形状对象，避免重新细分与上传。
    @Test(arguments: ["list/14.pag", "list/17.pag"])
    func repeatedRealFrameRetainsEveryShape(_ name: String) async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
        let scene = try await PreparedScene.prepare(file.composition)
        let first = try await FramePlanner.prepare(scene, at: .zero,
            targetSize: PAGSize(width: 500, height: 500), scale: 1, mode: .aspectFit)
        let second = try await FramePlanner.prepare(scene, at: .zero,
            targetSize: PAGSize(width: 500, height: 500), scale: 1, mode: .aspectFit)
        #expect(Set(first.shapes.keys.filter { $0.sampleFrame != nil }.map(\.source)).count > 4)
        #expect(Set(first.shapes.keys) == Set(second.shapes.keys))
        for (key, geometry) in first.shapes { #expect(second.shapes[key] === geometry) }
    }

    /// 超过四个源层仍各自保留近期结果；一层进入第五帧只淘汰自己的最旧采样。
    @Test func multipleSourcesKeepTheirOwnRecentSamples() async throws {
        let references = (0..<12).map { SourceLayerReference(composition: 0, layer: $0) }
        let elements = try ShapePathFixtures.elements(ShapePathFixtures.track())
        let store = try PreparedShapeStore(templates: Dictionary(uniqueKeysWithValues: references.map { ($0, elements) }))
        var initial: [PreparedShapeLayer] = []
        for reference in references {
            initial.append(try await store.sample(.init(source: reference, frame: 0), maximumPreparedBytes: 1_000_000))
        }
        for (reference, expected) in zip(references, initial) {
            #expect(try await store.sample(.init(source: reference, frame: 0), maximumPreparedBytes: 1_000_000) === expected)
        }
        for frame: Int64 in 1...4 {
            _ = try await store.sample(.init(source: references[0], frame: frame), maximumPreparedBytes: 1_000_000)
        }
        #expect(try await store.sample(.init(source: references[0], frame: 0), maximumPreparedBytes: 1_000_000) !== initial[0])
        for (reference, expected) in zip(references.dropFirst(), initial.dropFirst()) {
            #expect(try await store.sample(.init(source: reference, frame: 0), maximumPreparedBytes: 1_000_000) === expected)
        }
    }

    /// 65个小源层受全局64条限制，仍按访问顺序淘汰；不能因总字节很小而无界持有。
    @Test func globalEntryLimitStillEvictsLeastRecentSource() async throws {
        let references = (0..<65).map { SourceLayerReference(composition: 0, layer: $0) }
        let elements = try ShapePathFixtures.elements(ShapePathFixtures.track())
        let store = try PreparedShapeStore(templates: Dictionary(uniqueKeysWithValues: references.map { ($0, elements) }))
        var samples: [PreparedShapeLayer] = []
        for reference in references {
            samples.append(try await store.sample(.init(source: reference, frame: 0), maximumPreparedBytes: 1_000_000))
        }
        #expect(await store.retainedBytes == samples.dropFirst().reduce(0) { $0 + $1.estimatedBytes })
        #expect(try await store.sample(.init(source: references[1], frame: 0), maximumPreparedBytes: 1_000_000) === samples[1])
        #expect(try await store.sample(.init(source: references[0], frame: 0), maximumPreparedBytes: 1_000_000) !== samples[0])
        #expect(await store.retainedBytes <= 64 * 1024 * 1024)
    }

    /// 命中推进LRU，加入第五帧淘汰最旧帧；已经交给调用方的旧结果仍可用。
    @Test func boundedAccessOrderAndOldResources() async throws {
        let store = try makeStore()
        let first = try await sample(store, frame: 0)
        let second = try await sample(store, frame: 1)
        _ = try await sample(store, frame: 2)
        let fourth = try await sample(store, frame: 3)
        #expect(try await sample(store, frame: 0) === first)
        let fifth = try await sample(store, frame: 4)
        #expect(try await sample(store, frame: 0) === first)
        let renewed = try await sample(store, frame: 1)
        #expect(renewed !== second)
        // 端点共享源路径，段内插值另有分配，不能假设每个样本的逻辑成本相等。
        #expect(await store.retainedBytes == first.estimatedBytes + fourth.estimatedBytes + fifth.estimatedBytes + renewed.estimatedBytes)
        await store.removeAll()
        #expect(await store.retainedBytes == 0 && !first.geometries.isEmpty)
    }

    /// 字节上限可以比四条限制更先淘汰；禁用缓存时求值仍成功，但每次返回独立完整结果。
    @Test func byteBoundAndDisabledRetention() async throws {
        let probe = try makeStore()
        let measured = try await sample(probe, frame: 1)
        let compared = try await sample(probe, frame: 2)
        // 新帧还计同源候选和匹配成本；限额必须容纳单条完整结果，才是在测试字节淘汰。
        let limited = try makeStore(maximumBytes: max(measured.estimatedBytes, compared.estimatedBytes))
        let first = try await sample(limited, frame: 1)
        _ = try await sample(limited, frame: 2)
        let renewed = try await sample(limited, frame: 1)
        #expect(renewed !== first)
        #expect(await limited.retainedBytes == renewed.estimatedBytes)
        let disabled = try makeStore(maximumBytes: 0)
        let one = try await sample(disabled, frame: 1)
        #expect(try await sample(disabled, frame: 1) !== one)
        #expect(await disabled.retainedBytes == 0)
        #expect(throws: PAGError.invalidArgument("shapeCacheBytes")) { try makeStore(maximumBytes: -1) }
    }

    /// 单个段内结果超过缓存上限仍可使用，且不会为无法留存的结果挤掉较小端点样本。
    @Test func oversizedResultPreservesExistingEntry() async throws {
        let endpoint = try await sample(makeStore(), frame: 0)
        let store = try makeStore(maximumBytes: endpoint.estimatedBytes)
        let cached = try await sample(store, frame: 0)
        let oversized = try await sample(store, frame: 1)
        #expect(oversized.estimatedBytes > endpoint.estimatedBytes)
        #expect(try await sample(store, frame: 1) !== oversized)
        #expect(try await sample(store, frame: 0) === cached)
        #expect(await store.retainedBytes == endpoint.estimatedBytes)
    }

    /// 已命中仍检查调用方上限，失败与预取消不改LRU；未知源层明确失败，旧对象不失效。
    @Test func failureAndCancellationDoNotPublish() async throws {
        let store = try makeStore()
        let first = try await sample(store, frame: 0)
        for frame: Int64 in [0, 1] {
            await #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
                try await store.sample(key(frame), maximumPreparedBytes: 1)
            }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await sample(store, frame: 2)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await sample(store, frame: 0) === first)
        #expect(await store.retainedBytes == first.estimatedBytes)
        await #expect(throws: SceneValidator.invalid("missingPreparedShape")) {
            try await store.sample(ShapeSampleKey(source: SourceLayerReference(composition: 3, layer: 0), frame: 0),
                                   maximumPreparedBytes: 1_000_000)
        }
    }

    /// 仅构造一个动态源层模板，实例和doc身份的检查由PreparedScene/FramePlanner测试覆盖。
    private func makeStore(maximumBytes: Int = 64 * 1024 * 1024) throws -> PreparedShapeStore {
        try PreparedShapeStore(templates: [key(0).source: ShapePathFixtures.elements(ShapePathFixtures.track())], maximumBytes: maximumBytes)
    }

    /// 用固定源引用取一帧，计划预算每次独立，不依赖其他测试的缓存。
    private func sample(_ store: PreparedShapeStore, frame: Int64) async throws -> PreparedShapeLayer {
        try await store.sample(key(frame), maximumPreparedBytes: 1_000_000)
    }

    /// 返回测试源层与任意帧的合法缓存键。
    private func key(_ frame: Int64) -> ShapeSampleKey {
        ShapeSampleKey(source: SourceLayerReference(composition: 0, layer: 0), frame: frame)
    }
}
