import Testing
@testable import pag_swift

/// 验证生产场景准备确实装载源候选，并在编辑、换文档和预算边界保持纯值身份。
struct PreparedPictureCandidatesTests {
    /// 完整载入的red与fans分别保留层内容资格及定义级Vector排除，未把资格写进FramePlan。
    @Test func realFilesInstallCandidatesWithoutChangingPlan() async throws {
        let red = try await PAGLoader().load(data: PAGFixtures.data(named: "red.pag"))
        let fans = try await PAGLoader().load(data: PAGFixtures.data(named: "fans.pag"))
        let redScene = try await PreparedScene.prepare(red.composition)
        let fansScene = try await PreparedScene.prepare(fans.composition)
        let redIndex = try #require(red.storage.compositions.firstIndex { $0.id == 20010 })
        let child = try #require(fans.storage.compositions.firstIndex { $0.id == 2076 })
        let layer = try #require(fans.storage.compositions[child].layers.firstIndex { $0.id == 2098 })
        let root = try #require(fans.storage.compositions.firstIndex { $0.id == 2354 })
        #expect(redScene.pictureCandidates.layerContent[redIndex] == [true])
        #expect(redScene.pictureCandidates.vector[redIndex] == false)
        #expect(fansScene.pictureCandidates.layerContent[child][layer])
        #expect(fansScene.pictureCandidates.vector[child] == false)
        #expect(fansScene.pictureCandidates.vector[root] == false)
        #expect(redScene.estimatedPictureAnalysisBytes > 0)
        let frame = try await FramePlanner.prepare(redScene, at: .zero, targetSize: red.composition.size,
                                                   scale: 1, mode: .none)
        #expect(frame.plan.commands.allSatisfy { command in
            switch command {
            case .beginOpacityGroup(let group):
                if case .perDraw = group.application { return true }
                return false
            case .beginGroup(let group):
                if case .perDraw = group.application { return true }
                return false
            default: return true
            }
        })
    }

    /// 同源隐藏编辑可复用资格，但恰好少一字节的分析预算必须失败，不能用旧表绕过限额。
    @Test func sameStorageReusePaysCandidateCostAgain() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "red.pag"))
        let original = try await PreparedScene.prepare(file.composition)
        var edited = file.composition
        let layer = try #require(edited.layers.first)
        try edited.setVisibility(false, for: layer.id)
        let total = original.estimatedShapeBytes + original.imageTimes.estimatedBytes
            + original.estimatedPictureAnalysisBytes
        #expect(original.estimatedPictureAnalysisBytes > 0)
        let reused = try await PreparedScene.prepare(edited, reusing: original, maximumBytes: total)
        #expect(reused.pictureCandidates.layerContent == original.pictureCandidates.layerContent)
        #expect(reused.pictureCandidates.vector == original.pictureCandidates.vector)
        #expect(reused.estimatedPictureAnalysisBytes == original.estimatedPictureAnalysisBytes)
        await #expect(throws: PAGError.resourceLimitExceeded("maximumPreparedSceneBytes")) {
            try await PreparedScene.prepare(edited, reusing: original, maximumBytes: total - 1)
        }
    }

    /// 新源即使沿用相同定义ID也要重新分析；预取消不返回带部分候选的场景。
    @Test func differentStorageReanalyzesAndCancellationIsAtomic() async throws {
        let first = try SceneFixtures.build([SceneFixtures.composition(1, layers: [SceneFixtures.layer(11), SceneFixtures.layer(12)])])
        let second = try SceneFixtures.build([SceneFixtures.composition(1, layers: [SceneFixtures.layer(11)])])
        let original = try await PreparedScene.prepare(first.composition)
        let replaced = try await PreparedScene.prepare(second.composition, reusing: original)
        #expect(original.pictureCandidates.vector == [true])
        #expect(replaced.pictureCandidates.vector == [false])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PreparedScene.prepare(second.composition, reusing: replaced)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
