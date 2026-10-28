import Testing
@testable import pag_swift

/// 新增形状轨道进入共同FramePlan和既有四项缓存后的实例时间、保活及失败原子性。
struct ShapePropertyPlanningTests {
    /// 同源两个实例分别求源帧5/10，不再次减图层起点；颜色独立，只有几何不变时共享对象。
    @Test(arguments: [false, true])
    func instancesUseDistinctSourceFrames(_ movesRectangle: Bool) async throws {
        let position = try ShapePropertyFixtures.track(ScenePoint.zero, ScenePoint(x: 20, y: 40))
        let color = try ShapePropertyFixtures.track(SceneColor(red: 0, green: 0, blue: 255), .defaultFill)
        let group = ShapePropertyFixtures.group(opacity: try ShapePropertyFixtures.track(UInt8(100), UInt8(200)))
        let elements: [SourceShape] = [.group(group, [ShapePropertyFixtures.rectangle(
            position: movesRectangle ? position : .init(constant: .zero)), ShapePropertyFixtures.fill(color: color)])]
        let file = try ShapePropertyFixtures.file(elements, start: 5)
        let scene = try await PreparedScene.prepare(file.composition)
        #expect(scene.shapes.isEmpty && scene.dynamicShapes != nil)
        let frame = try await ShapePathFixtures.plan(scene, at: 10)
        let paints = ShapePathFixtures.fills(frame)
        try #require(paints.count == 2 && frame.shapes.count == 2)
        #expect(Set(paints.compactMap(\.geometryID.sampleFrame)) == [5, 10])
        for paint in paints {
            let sample = try #require(paint.geometryID.sampleFrame)
            #expect(try paint.material.solidColor().red == (sample == 5 ? 127 : 255))
            let geometry = try #require(frame.shapes[paint.geometryID])
            guard case .rectangle(let contour) = geometry.contours[0] else {
                Issue.record("实例必须保留完整矩形几何")
                return
            }
            #expect(contour.center == (movesRectangle ? ScenePoint(x: Double(sample) * 2, y: Double(sample) * 4) : .zero))
        }
        let first = try #require(frame.shapes[paints[0].geometryID])
        let second = try #require(frame.shapes[paints[1].geometryID])
        #expect((first === second) == (movesRectangle == false))
    }

    /// 新模型的常量组/矩形/fill仍只在安装时准备，不创建动态owner或为每帧复制几何。
    @Test func constantsStayOnStaticInstallationPath() async throws {
        let elements: [SourceShape] = [.group(ShapePropertyFixtures.group(),
            [ShapePropertyFixtures.rectangle(), ShapePropertyFixtures.fill()])]
        let file = try ShapePropertyFixtures.file(elements, offsets: [0])
        let scene = try await PreparedScene.prepare(file.composition)
        #expect(scene.shapes.count == 1 && scene.dynamicShapes == nil)
        let first = try await ShapePathFixtures.plan(scene, at: 0)
        let last = try await ShapePathFixtures.plan(scene, at: 20)
        let id = try #require(ShapePathFixtures.fills(first).first?.geometryID)
        #expect(id.sampleFrame == nil && first.shapes[id] === last.shapes[id])
    }

    /// 一个计划含五种采样再重复第一种时，帧内保活表仍复用首对象，不被四项owner淘汰覆盖。
    @Test func planRetentionOutlivesFourEntryEviction() async throws {
        let elements = [ShapePropertyFixtures.rectangle(position: try ShapePropertyFixtures.track(.zero, ScenePoint(x: 20, y: 40))),
                        ShapePropertyFixtures.fill()]
        let file = try ShapePropertyFixtures.file(elements, offsets: [0, 1, 2, 3, 4, 0])
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await ShapePathFixtures.plan(scene, at: 10)
        let paints = ShapePathFixtures.fills(frame)
        try #require(paints.count == 6 && frame.shapes.count == 5)
        let first = paints[0].geometryID
        #expect(first == paints.last?.geometryID)
        let old = try #require(frame.shapes[first])
        let owner = try #require(scene.dynamicShapes)
        let rebuilt = try await owner.sample(ShapeSampleKey(source: first.source, frame: 10), maximumPreparedBytes: 1_000_000)
        #expect(rebuilt.geometries[0] !== old)
    }

    /// 准备失败/取消不发布缓存、不改原对象；同源重命中保留身份，独立owner不共享可变缓存。
    @Test func failedSamplesDoNotPublishOrDisplacePriorState() async throws {
        let largest = Double(Float.greatestFiniteMagnitude)
        let transform = ShapePropertyFixtures.group(skew: try ShapePropertyFixtures.track(-largest, largest))
        let elements: [SourceShape] = [.group(transform, [ShapePropertyFixtures.rectangle(), ShapePropertyFixtures.fill()])]
        let store = try PreparedShapeStore(templates: [key(0).source: elements])
        let first = try await store.sample(key(0), maximumPreparedBytes: 1_000_000)
        let bytes = await store.retainedBytes
        await #expect(throws: SceneValidator.invalid("unrepresentablePropertyValue")) {
            try await store.sample(key(5), maximumPreparedBytes: 1_000_000)
        }
        await #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try await store.sample(key(0), maximumPreparedBytes: first.estimatedBytes - 1)
        }
        await #expect(throws: CancellationError.self) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.cancelAll()
                group.addTask { _ = try await store.sample(key(10), maximumPreparedBytes: 1_000_000) }
                for try await _ in group {}
            }
        }
        #expect(await store.retainedBytes == bytes)
        #expect(try await store.sample(key(0), maximumPreparedBytes: 1_000_000) === first)
        let other = try PreparedShapeStore(templates: [key(0).source: elements])
        #expect(try await other.sample(key(0), maximumPreparedBytes: 1_000_000).geometries[0] !== first.geometries[0])
    }

    /// 纯语义模板的唯一源层引用，帧键沿用源合成坐标。
    private func key(_ frame: Int64) -> ShapeSampleKey {
        ShapeSampleKey(source: SourceLayerReference(composition: 0, layer: 0), frame: frame)
    }
}
