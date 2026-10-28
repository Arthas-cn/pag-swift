import Testing
@testable import pag_swift

/// 静态/动画路径共用FramePlan与复合几何，验证源时钟、实例身份和生命周期复用。
struct ShapePathPlanningTests {
    /// 动态路径按所属合成帧取样，不减图层起点；共享源的两个实例分别保留10与5帧几何。
    @Test func instancesUseCompositionFramesWithoutCollision() async throws {
        let file = try ShapePathFixtures.file(ShapePathFixtures.track(), start: 5)
        let scene = try await PreparedScene.prepare(file.composition)
        #expect(scene.shapes.isEmpty && scene.dynamicShapes != nil)
        let plan = try await ShapePathFixtures.plan(scene, at: 10)
        let fills = ShapePathFixtures.fills(plan)
        #expect(fills.count == 2 && plan.shapes.count == 2)
        #expect(Set(fills.compactMap(\.geometryID.sampleFrame)) == [5, 10])
        for fill in fills {
            let geometry = try #require(plan.shapes[fill.geometryID])
            var budget = try GeometryBudget()
            let mesh = try RenderGeometrySource.shape(geometry).prepare(precision: GeometryPrecision(transform: .identity), budget: &budget)
            let frame = try #require(fill.geometryID.sampleFrame)
            #expect(abs(GeometryTestSupport.area(mesh) - (frame == 10 ? 400 : 225)) < 1e-8)
        }
        #expect(plan.plan.time.frame == 10)
    }

    /// 静态路径只准备一次，后续帧/编辑快照共享几何；动态owner只在同一源存储显式复用。
    @Test func staticGeometryAndDynamicOwnersHaveSeparateReuse() async throws {
        let property = try SourceProperty(constant: ShapePathFixtures.square(10))
        let file = try ShapePathFixtures.file(property)
        let scene = try await PreparedScene.prepare(file.composition)
        #expect(scene.dynamicShapes == nil && scene.shapes.count == 1)
        let first = try await ShapePathFixtures.plan(scene, at: 10)
        let second = try await ShapePathFixtures.plan(scene, at: 20)
        let id = try #require(ShapePathFixtures.fills(first).first?.geometryID)
        #expect(id.sampleFrame == nil && first.shapes[id] === second.shapes[id])
        let dynamicFile = try ShapePathFixtures.file(ShapePathFixtures.track())
        let dynamic = try await PreparedScene.prepare(dynamicFile.composition)
        let reused = try await PreparedScene.prepare(dynamicFile.composition, reusing: dynamic)
        let independent = try await PreparedScene.prepare(dynamicFile.composition)
        #expect(dynamic.dynamicShapes === reused.dynamicShapes)
        #expect(dynamic.dynamicShapes !== independent.dynamicShapes)
        await #expect(throws: PAGError.resourceLimitExceeded("maximumPreparedSceneBytes")) {
            try await PreparedScene.prepare(dynamicFile.composition, reusing: dynamic, maximumBytes: 1)
        }
    }

    /// 一个计划超过owner四条缓存后再遇到第一采样，应复用本帧对象，不重建或覆写同ID。
    @Test func perPlanRetentionSurvivesOwnerEviction() async throws {
        let file = try ShapePathFixtures.file(ShapePathFixtures.track(), offsets: [0, 1, 2, 3, 4, 0])
        let scene = try await PreparedScene.prepare(file.composition)
        let plan = try await ShapePathFixtures.plan(scene, at: 10)
        let fills = ShapePathFixtures.fills(plan)
        #expect(fills.count == 6 && plan.shapes.count == 5)
        let first = try #require(fills.first)
        #expect(first.geometryID == fills.last?.geometryID)
        let old = try #require(plan.shapes[first.geometryID])
        let owner = try #require(scene.dynamicShapes)
        let key = ShapeSampleKey(source: first.geometryID.source, frame: 10)
        let rebuilt = try await owner.sample(key, maximumPreparedBytes: 1_000_000)
        // 最后一个重复实例若重访owner会重新留下帧10；这里确认它确实只查询本帧保活表。
        #expect(rebuilt.geometries[0] !== old)
        #expect(old.contours.count == 1)
    }

    /// 计划取消和低预算不能绕过动态缓存发布；先前取得的完整帧仍保有几何。
    @Test func planBudgetAndCancellationPreservePriorFrame() async throws {
        let file = try ShapePathFixtures.file(ShapePathFixtures.track())
        let scene = try await PreparedScene.prepare(file.composition)
        let old = try await ShapePathFixtures.plan(scene, at: 10)
        await #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try await FramePlanner.prepare(scene, at: .zero, targetSize: file.composition.size, scale: 1, mode: .none, maximumBytes: 1)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ShapePathFixtures.plan(scene, at: 15)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(old.shapes.count == 2)
    }
}
