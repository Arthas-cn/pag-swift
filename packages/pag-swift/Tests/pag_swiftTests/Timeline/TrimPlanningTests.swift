import Testing
@testable import pag_swift

/// Trim进入共同计划与四项缓存后，身份、实例源时间和失败发布仍由原后台所有者管理。
struct TrimPlanningTests {
    /// 颜色和描边宽度动画不重建连续Trim输出；只有宽度改变描边几何，渐变材料也独立缓存。
    @Test func paintTracksReuseConsecutiveTrimBatches() throws {
        let path = try ShapePathFixtures.square(20)
        let color = try ShapePropertyFixtures.track(SceneColor.defaultFill, SceneColor(red: 0, green: 0, blue: 255))
        let elements: [SourceShape] = [.path(.init(constant: path)),
            .trimPaths(TrimBatchFixtures.source(0, 0.75)), .trimPaths(TrimBatchFixtures.source(0, 0.75)),
            ShapePropertyFixtures.fill(color: color), .stroke(StrokeFixtures.make(width: try ShapePropertyFixtures.track(2.0, 4))),
            .gradientFill(.init(compositeOrder: .abovePrevious, gradient: GradientShapeFixtures.gradient()))]
        let first = try TrimBatchFixtures.prepare(elements)
        let changed = try TrimBatchFixtures.prepare(elements, frame: 5, reusing: [first])
        for ordinal in [0, 1] {
            #expect(first.trimBatchesByModifier[ordinal] === changed.trimBatchesByModifier[ordinal])
        }
        #expect(try StrokeShapeFixtures.geometry(first, ordinal: 0) === StrokeShapeFixtures.geometry(changed, ordinal: 0))
        #expect(try StrokeShapeFixtures.geometry(first, ordinal: 1) !== StrokeShapeFixtures.geometry(changed, ordinal: 1))
        #expect(first.gradientColorizersByPaint[2] === changed.gradientColorizersByPaint[2])
    }

    /// 同源实例按源合成帧5/10裁剪，不再次减图层起点；不同采样帧的输出身份不能混用。
    @Test func instancesUseSourceFramesAndStaticTrimStaysStatic() async throws {
        let animated = try elements(animated: true)
        let file = try ShapePropertyFixtures.file(animated, start: 5)
        let scene = try await PreparedScene.prepare(file.composition)
        #expect(scene.shapes.isEmpty && scene.dynamicShapes != nil)
        let frame = try await ShapePathFixtures.plan(scene, at: 10)
        let paints = ShapePathFixtures.fills(frame)
        try #require(paints.count == 2)
        #expect(Set(paints.compactMap(\.geometryID.sampleFrame)) == [5, 10])
        for paint in paints {
            let geometry = try #require(frame.shapes[paint.geometryID])
            let path = try TrimBatchFixtures.path(geometry.contours[0]).path
            #expect(path.points.last?.x == (paint.geometryID.sampleFrame == 5 ? 10 : 15))
        }
        let constantFile = try ShapePropertyFixtures.file(elements(animated: false), offsets: [0])
        let constant = try await PreparedScene.prepare(constantFile.composition)
        #expect(constant.shapes.count == 1 && constant.dynamicShapes == nil)
    }

    /// Trim批次随四项LRU淘汰，已交出的旧帧仍有效；预算失败和预取消不改变缓存。
    @Test func retentionEvictionFailureAndCancellationAreAtomic() async throws {
        let store = try PreparedShapeStore(templates: [key(0).source: elements(animated: true)])
        let first = try await sample(store, 0)
        let second = try await sample(store, 1)
        _ = try await sample(store, 2)
        let fourth = try await sample(store, 3)
        #expect(try await sample(store, 0) === first)
        let fifth = try await sample(store, 4)
        let renewed = try await sample(store, 1)
        #expect(renewed !== second)
        let retained = first.estimatedBytes + fourth.estimatedBytes + fifth.estimatedBytes + renewed.estimatedBytes
        #expect(await store.retainedBytes == retained)
        await #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try await store.sample(key(4), maximumPreparedBytes: fifth.estimatedBytes - 1)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await sample(store, 5)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await store.retainedBytes == retained)
        #expect(try await sample(store, 4) === fifth)
        await store.removeAll()
        #expect(await store.retainedBytes == 0)
        #expect(try TrimBatchFixtures.path(first.geometries[0].contours[0]).path.points.last?.x == 5)
    }

    /// 单次ShapePreparation的全部modifier共享工作额度，不因新modifier或空路径获得新预算。
    @Test func modifiersShareOneGeometryWorkBudget() throws {
        let source = SourceShape.trimPaths(TrimBatchFixtures.source(0, 0.5))
        var builder = ShapeContentPreparation(budget: FramePlanBudget(limit: 1_000_000),
            geometryBudget: try GeometryBudget(maximumWork: 1), frame: 0, candidates: [])
        // 空列表的第一次Trim也消费入口工作；第二次必须失败，检出每modifier重置预算的实现。
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try builder.group([source, source], matrix: .identity, depth: 0)
        }
        #expect(builder.trimBatchesByModifier.count == 1 && builder.geometryBudget.work == 1)
    }

    /// 透明或没有路径的Trim轨道仍影响动画分类，不能由当前输出是否为空决定静态缓存。
    @Test func invisibleTrimTracksRemainAnimated() throws {
        let track = try ShapePropertyFixtures.track(0.0, 0.5)
        for trim in [SourceTrimPaths(start: track, end: .init(constant: 1), offset: .init(constant: 0), mode: .simultaneously),
                     SourceTrimPaths(start: .init(constant: 0), end: track, offset: .init(constant: 0), mode: .simultaneously),
                     SourceTrimPaths(start: .init(constant: 0), end: .init(constant: 1), offset: track, mode: .simultaneously)] {
            var budget = FramePlanBudget(limit: 1_000_000)
            #expect(try ShapePreparation.isAnimated([.group(TrimBatchFixtures.transform(opacity: 0), [.trimPaths(trim)])], budget: &budget))
        }
    }

    /// 一条20单位Line的末端从1/4到3/4，便于独立断言源采样帧对应的x坐标。
    private func elements(animated: Bool) throws -> [SourceShape] {
        let end = try animated ? ShapePropertyFixtures.track(0.25, 0.75) : SourceProperty(constant: 0.25)
        return [.path(.init(constant: try TrimBatchFixtures.line(20))), .trimPaths(SourceTrimPaths(
            start: .init(constant: 0), end: end, offset: .init(constant: 0), mode: .simultaneously)), ShapePropertyFixtures.fill()]
    }

    /// 固定模板身份，帧保持源合成坐标。
    private func key(_ frame: Int64) -> ShapeSampleKey {
        ShapeSampleKey(source: SourceLayerReference(composition: 0, layer: 0), frame: frame)
    }

    /// 每次调用独立帧计划额度；缓存内部仍检查完整保活成本。
    private func sample(_ store: PreparedShapeStore, _ frame: Int64) async throws -> PreparedShapeLayer {
        try await store.sample(key(frame), maximumPreparedBytes: 1_000_000)
    }
}
