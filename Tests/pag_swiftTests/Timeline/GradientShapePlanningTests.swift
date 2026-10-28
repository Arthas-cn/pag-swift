import Testing
@testable import pag_swift

/// 渐变通过现有动态owner和公共帧计划，实例时钟、原子失败与缓存归属保持一致。
struct GradientShapePlanningTests {
    /// 同源实例分别采样帧5/10，端点不混用，颜色和几何共享；静态材料仍在安装期准备。
    @Test func instanceTimesAndStaticInstallationRemainDistinct() async throws {
        let elements = try GradientShapeFixtures.animated(1)
        let file = try ShapePropertyFixtures.file(elements, start: 5)
        let scene = try await PreparedScene.prepare(file.composition)
        #expect(scene.shapes.isEmpty && scene.dynamicShapes != nil)
        let frame = try await ShapePathFixtures.plan(scene, at: 10)
        let paints = ShapePathFixtures.fills(frame)
        try #require(paints.count == 2)
        #expect(Set(paints.compactMap(\.geometryID.sampleFrame)) == [5, 10])
        #expect(frame.shapes[paints[0].geometryID] === frame.shapes[paints[1].geometryID])
        let a = try paints[0].material.gradientValue(), b = try paints[1].material.gradientValue()
        #expect(a.colorizer === b.colorizer)
        for paint in paints {
            let sample = try #require(paint.geometryID.sampleFrame)
            #expect(try paint.material.gradientValue().end.x == (sample == 5 ? 65 : 80))
        }
        let staticFile = try ShapePropertyFixtures.file(GradientShapeFixtures.elements(GradientShapeFixtures.gradient()), offsets: [0])
        let installed = try await PreparedScene.prepare(staticFile.composition)
        #expect(installed.shapes.count == 1 && installed.dynamicShapes == nil)
        let first = try await ShapePathFixtures.plan(installed, at: 0)
        let last = try await ShapePathFixtures.plan(installed, at: 20)
        let firstPaint = try #require(ShapePathFixtures.fills(first).first)
        let lastPaint = try #require(ShapePathFixtures.fills(last).first)
        #expect(first.shapes[firstPaint.geometryID] === last.shapes[lastPaint.geometryID])
        #expect(try firstPaint.material.gradientValue().colorizer === lastPaint.material.gradientValue().colorizer)
    }

    /// 相同ordinal和源颜色引用也不跨源层复用程序；失败、取消和LRU淘汰不破坏已返回材料。
    @Test func ownerKeepsSourceBoundariesAndAtomicPublication() async throws {
        let colors = GradientColorFixtures.colors()
        let invalid = SourceGradientColors(alphaStops: [], colorStops: [])
        let track = try ShapePropertyFixtures.track(colors, invalid, easing: .hold)
        let elements = GradientShapeFixtures.elements(GradientShapeFixtures.gradient(colors: track))
        let a = SourceLayerReference(composition: 0, layer: 0), b = SourceLayerReference(composition: 0, layer: 1)
        let store = try PreparedShapeStore(templates: [a: elements, b: elements])
        let key = ShapeSampleKey(source: a, frame: 0)
        let first = try await store.sample(key, maximumPreparedBytes: 1_000_000)
        let other = try await store.sample(.init(source: b, frame: 0), maximumPreparedBytes: 1_000_000)
        #expect(first.gradientColorizersByPaint[0] !== other.gradientColorizersByPaint[0])
        let retained = await store.retainedBytes
        await #expect(throws: SceneValidator.invalid("emptyGradientStops")) {
            try await store.sample(.init(source: a, frame: 10), maximumPreparedBytes: 1_000_000)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.sample(.init(source: a, frame: 2), maximumPreparedBytes: 1_000_000)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await store.retainedBytes == retained)
        #expect(try await store.sample(key, maximumPreparedBytes: 1_000_000) === first)
        for frame: Int64 in 1...5 {
            let value = try await store.sample(.init(source: a, frame: frame), maximumPreparedBytes: 1_000_000)
            #expect(value.gradientColorizersByPaint[0] === first.gradientColorizersByPaint[0])
        }
        #expect(try await store.sample(key, maximumPreparedBytes: 1_000_000) !== first)
        await store.removeAll()
        #expect(await store.retainedBytes == 0)
        #expect(first.gradientColorizersByPaint[0]?.source === colors)
    }

    /// 去除必须保活的源表成本后，暖准备计费与原stop数量无关，不重新展开4096项。
    @Test func warmPreparationHasFixedWorkBeyondRetention() throws {
        var overhead: [Int] = []
        for count in [2, 4096] {
            let colors = GradientColorFixtures.colors(rgb: (0..<count).map {
                (Float($0) / Float(count - 1), SceneColor(red: UInt8($0 % 256), green: 0, blue: 0))
            })
            let elements = try GradientShapeFixtures.elements(GradientShapeFixtures.gradient(
                end: ShapePropertyFixtures.track(ScenePoint(x: 50, y: 10), ScenePoint(x: 80, y: 10)),
                colors: .init(constant: colors)))
            let cold = try ShapePropertyFixtures.prepare(elements)
            let warm = try ShapePropertyFixtures.prepare(elements, frame: 5, reuse: [cold])
            let program = try #require(warm.gradientColorizersByPaint[0])
            #expect(program === cold.gradientColorizersByPaint[0])
            overhead.append(warm.estimatedBytes - program.estimatedBytes)
        }
        #expect(overhead[0] == overhead[1])
    }
}
