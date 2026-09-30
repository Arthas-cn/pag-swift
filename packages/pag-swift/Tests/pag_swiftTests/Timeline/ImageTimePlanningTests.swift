import Testing
@testable import pag_swift

/// 图片素材时钟进入共同计划的边界；不增加P8媒体工厂，也不改根帧、原图或其他图层的时钟。
struct ImageTimePlanningTests {
    /// 共享源在两个偏移实例中有独立素材时间；替换使用规则缩放，恢复原图与旧快照均不受影响。
    @Test func sharedInstancesReplacementAndRestoreUseIndependentTimes() async throws {
        let rule = try ImageTimeFixtures.rule([ImageTimeFixtures.key(2, 12, 10, 30)], mode: .none)
        let file = try await ImageTimeFixtures.file(rule: rule)
        let original = try await PreparedScene.prepare(file.composition)
        let old = try await plan(original, frame: 7)
        #expect(images(old).map(\.contentTime.microseconds) == [33_334, 166_667])
        var edited = file.composition
        try edited.replaceImage(try #require(file.storage.resources.images[1]?.image), at: 0)
        let changed = try await PreparedScene.prepare(edited, reusing: original)
        #expect(changed.imageTimes === original.imageTimes)
        let changedPlan = try await plan(changed, frame: 7)
        #expect(images(changedPlan).map(\.contentTime.microseconds) == [66_667, 333_334])
        #expect(images(changedPlan).allSatisfy { $0.matrix == .identity && $0.clip != nil })
        #expect(changedPlan.plan.time.frame == 7 && old.plan.time.frame == 7)
        try edited.replaceImage(nil, at: 0)
        let restored = try await PreparedScene.prepare(edited, reusing: changed)
        #expect(restored.imageTimes === original.imageTimes)
        #expect(images(try await plan(restored, frame: 7)).map(\.contentTime) == images(old).map(\.contentTime))
        #expect(images(old).allSatisfy { $0.matrix == .identity && $0.clip == nil })
        #expect(images(changedPlan).map(\.contentTime.microseconds) == [66_667, 333_334])
    }

    /// 父30fps/子15fps按源时钟映射到根7...27，闭区间比例21/11使中点素材帧为19.5。
    @Test func mixedRatesUseDocumentedSourceClock() async throws {
        let rule = try ImageTimeFixtures.rule([ImageTimeFixtures.key(2, 12, 10, 30)])
        let file = try await ImageTimeFixtures.file(rule: rule, offsets: [3], childRate: 15)
        var edited = file.composition
        try edited.replaceImage(try #require(file.storage.resources.images[1]?.image), named: "image")
        let scene = try await PreparedScene.prepare(edited)
        let mapping = try #require(scene.imageTimes.mappings.values.first)
        #expect(mapping.visibleStart == 7 && mapping.visibleEnd == 27)
        let frame = try await plan(scene, frame: 17)
        #expect(frame.plan.time.frame == 17 && images(frame).first?.contentTime.microseconds == 650_000)
    }

    /// 真实可达的巨大源起点经负预合成偏移进入根，默认时钟保留CreateKeyframe的Float量化。
    @Test func largeSourceFrameOffsetReachesSmallRootTimeline() async throws {
        let file = try await ImageTimeFixtures.file(rule: nil, start: 16_777_217, duration: 9,
            offsets: [-16_777_216], childRate: 1, rootRate: 1, fileDuration: 9, childDuration: 16_777_226)
        var edited = file.composition
        try edited.replaceImage(try #require(file.storage.resources.images[1]?.image), at: 0)
        let scene = try await PreparedScene.prepare(edited)
        let mapping = try #require(scene.imageTimes.mappings.values.first)
        #expect(mapping.visibleStart == 0 && mapping.visibleEnd == 8)
        let frame = try await plan(scene, frame: 4)
        #expect(frame.plan.time.frame == 4 && images(frame).first?.contentTime.microseconds == 4_571_429)
    }

    /// 根包装也执行同帧率Float映射，覆盖直接根image及巨大奇数预合成偏移，而非只测深层祖先。
    @Test func rootWrapperQuantizesDirectAndNestedVisibleRanges() async throws {
        let fixture = try await ImageTimeFixtures.file(rule: nil, start: 16_777_217, duration: 9,
            offsets: [0], childRate: 1, rootRate: 1, fileDuration: 16_777_248)
        let direct = try SceneFixtures.build([fixture.storage.compositions[0]], resources: fixture.storage.resources)
        let nested = try await ImageTimeFixtures.file(rule: nil, start: 0, duration: 9,
            offsets: [16_777_217], childRate: 1, rootRate: 1, fileDuration: 16_777_248, childDuration: 9)
        for (file, expected) in [(direct, Int64(5_000_000)), (nested, 4_000_000)] {
            var edited = file.composition
            try edited.replaceImage(try #require(file.storage.resources.images[1]?.image), at: 0)
            let scene = try await PreparedScene.prepare(edited)
            let mapping = try #require(scene.imageTimes.mappings.values.first)
            #expect(mapping.visibleStart == 16_777_216 && mapping.visibleEnd == 16_777_224)
            let frame = try await plan(scene, frame: 16_777_220)
            #expect(frame.plan.time.frame == 16_777_220 && images(frame).first?.contentTime.microseconds == expected)
        }
    }

    /// 真实规则片段进入语义合成，V1在100帧线性推进而V2保持0；默认LetterBox覆盖文件stretch。
    @Test func realRuleVersionsAndDefaultScaleReachPlan() async throws {
        for version: UInt16 in [54, 67] {
            let file = try await ImageTimeFixtures.file(rule: ImageTimeFixtures.realRule(version: version),
                start: 22, duration: 401, offsets: [0], fileDuration: 500)
            var edited = file.composition
            try edited.replaceImage(try #require(file.storage.resources.images[1]?.image), at: 0)
            let scene = try await PreparedScene.prepare(edited)
            let frame = try await plan(scene, frame: 100)
            let image = try #require(images(frame).first)
            #expect(image.matrix == (try SceneAffine(a: 40, b: 0, c: 0, d: 40, tx: 10, ty: 0)))
            if version == 54 { #expect(abs(image.contentTime.microseconds - 5_509_934) <= 2) }
            else { #expect(image.contentTime == .zero) }
            #expect(frame.plan.time.frame == 100)
        }
    }

    /// 完整准备与复用都受预算限制，取消不返回部分时钟；不同源存储不能按内容身份误复用。
    @Test func preparationBudgetCancellationAndStorageIdentity() async throws {
        let file = try await ImageTimeFixtures.file(rule: nil)
        let scene = try await PreparedScene.prepare(file.composition)
        let cost = scene.imageTimes.estimatedBytes
        #expect(cost > 0)
        await #expect(throws: PAGError.resourceLimitExceeded("maximumPreparedSceneBytes")) {
            try await PreparedScene.prepare(file.composition, reusing: scene, maximumBytes: cost - 1)
        }
        await #expect(throws: PAGError.resourceLimitExceeded("maximumPreparedSceneBytes")) {
            try await PreparedScene.prepare(file.composition, maximumBytes: cost - 1)
        }
        let another = try await ImageTimeFixtures.file(rule: nil)
        let other = try await PreparedScene.prepare(another.composition, reusing: scene)
        #expect(other.imageTimes !== scene.imageTimes)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) { try await PreparedScene.prepare(file.composition) }
        }
        await task.value
    }

    /// 按根真实帧率生成请求，正式FramePlanner负责量化、实例采样和素材命令。
    private func plan(_ scene: PreparedScene, frame: Int64) async throws -> PreparedFrame {
        let root = scene.composition.storage.compositions[scene.composition.storage.rootIndex]
        let time = try SceneValidator.time(frame: frame, rate: root.frameRate)
        return try await FramePlanner.prepare(scene, at: time, targetSize: scene.composition.size, scale: 1, mode: .none)
    }

    /// 只收集图片图元，保留原计划的实际绘制与实例顺序。
    private func images(_ frame: PreparedFrame) -> [FrameImage] {
        frame.plan.commands.compactMap { if case .image(let image) = $0 { image } else { nil } }
    }
}
