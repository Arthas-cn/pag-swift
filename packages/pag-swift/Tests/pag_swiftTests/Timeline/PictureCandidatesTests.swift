import Foundation
import Testing
@testable import pag_swift

/// 验证Auto层内容及额外Vector Picture的纯值候选，不把资格当作GPU快照成功。
struct PictureCandidatesTests {
    /// red唯一Shape层可请求内容Picture但不满足多层Vector；fans外层动画只取消Vector资格。
    @Test func realRedAndFansKeepLayerAndVectorDecisionsSeparate() async throws {
        let red = try await PAGSceneDecoder.decode(PAGFixtures.data(named: "red.pag"))
        let fans = try await PAGSceneDecoder.decode(PAGFixtures.data(named: "fans.pag"))
        var redBudget = FramePlanBudget(limit: 8 * 1024 * 1024)
        let redCandidates = try Self.make(red.storage.compositions, budget: &redBudget)
        let redIndex = try #require(red.storage.compositions.firstIndex { $0.id == 20010 })
        #expect(redCandidates.layerContent[redIndex] == [true])
        #expect(redCandidates.vector[redIndex] == false)
        var fansBudget = FramePlanBudget(limit: 8 * 1024 * 1024)
        let fansCandidates = try Self.make(fans.storage.compositions, budget: &fansBudget)
        let child = try #require(fans.storage.compositions.firstIndex { $0.id == 2076 })
        let layer = try #require(fans.storage.compositions[child].layers.firstIndex { $0.id == 2098 })
        let root = try #require(fans.storage.compositions.firstIndex { $0.id == 2354 })
        #expect(fansCandidates.layerContent[child][layer])
        #expect(fansCandidates.vector[child] == false && fansCandidates.vector[root] == false)
    }

    /// 同一静态Shape即使外层Transform动画仍是内容候选；内部属性动画和单帧层都不候选。
    @Test func shapeContentIgnoresOuterTracksButRequiresCompleteMultiFrameRange() throws {
        let anchor = try SourceProperty(keyframes: [SourceKeyframe(startFrame: 10, endFrame: 20,
            startValue: ScenePoint.zero, endValue: ScenePoint.zero, easing: .linear, spatialCurve: nil)])
        let transform = SourceTransformProperties(anchor: anchor, position: .combined(.init(constant: .zero)),
            scale: .init(constant: .one), rotation: .init(constant: 0), opacity: .init(constant: 255))
        let staticLayer = SceneFixtures.layer(1, transform: transform, content: .shape([ShapePropertyFixtures.fill()]))
        let animated = SceneFixtures.layer(2, content: .shape([try ShapeRangeFixtures.element("fill", selected: 1)]))
        let single = SceneFixtures.layer(3, duration: 1, content: .shape([ShapePropertyFixtures.fill()]))
        var budget = FramePlanBudget(limit: 1_000_000)
        let candidates = try Self.make([SceneFixtures.composition(1, layers: [staticLayer, animated, single])], budget: &budget)
        #expect(candidates.layerContent[0] == [true, false, false])
        #expect(candidates.vector[0] == false)
    }

    /// 动态外层蒙版不能污染静态Shape内容Picture；Vector若含该蒙版则不得跨帧请求父快照。
    @Test func animatedMaskKeepsLayerPictureButDisablesVector() throws {
        let path = try SourcePath(verbs: [.move, .line, .close],
                                  points: [.zero, ScenePoint(x: 10, y: 0)])
        let mask = MaskTestSupport.mask(try SourceProperty(keyframes: [SourceKeyframe(
            startFrame: 10, endFrame: 20, startValue: path, endValue: path,
            easing: .linear, spatialCurve: nil)]))
        let shape = SceneFixtures.layer(1, content: .shape([ShapePropertyFixtures.fill()]), masks: [mask])
        let source = try SceneFixtures.composition(1, layers: [shape, SceneFixtures.layer(2)])
        var budget = FramePlanBudget(limit: 1_000_000)
        let candidates = try Self.make([source], budget: &budget)
        #expect(candidates.layerContent[0] == [true, false])
        #expect(candidates.vector == [false])
    }

    /// 静态mask也暂不进入定义级局部快照；祖先Vector保守回退而本层Shape内容仍可复用。
    @Test func staticMaskDisablesOwnAndAncestorVectorOnly() throws {
        let path = try SourcePath(verbs: [.move, .line, .close],
                                  points: [.zero, ScenePoint(x: 10, y: 0)])
        let mask = MaskTestSupport.mask(.init(constant: path))
        let child = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(11, content: .shape([ShapePropertyFixtures.fill()]), masks: [mask]),
            SceneFixtures.layer(12)
        ])
        let root = try SceneFixtures.composition(2, layers: [
            SceneFixtures.layer(21, content: .precomposition(id: 1, startFrame: 0)),
            SceneFixtures.layer(22)
        ])
        var budget = FramePlanBudget(limit: 1_000_000)
        let candidates = try Self.make([root, child], budget: &budget)
        #expect(candidates.layerContent[1] == [true, false])
        #expect(candidates.vector == [false, false])
    }

    /// Text的源内容静态资格不随编辑覆盖改变；实际文本资源身份仍由后续缓存实现区分。
    @Test func textEditKeepsCandidateButNotSourceStorageMutation() throws {
        let layer = SceneFixtures.layer(1, content: .text(try TextFixtures.source("A")))
        let file = try SceneFixtures.build([SceneFixtures.composition(1, layers: [layer])])
        var budget = FramePlanBudget(limit: 1_000_000)
        let original = try Self.make(file.storage.compositions, budget: &budget)
        var edited = file.composition
        var text = try edited.text(at: 0)
        text.text = "B"
        try edited.replaceText(text, at: 0)
        var editedBudget = FramePlanBudget(limit: 1_000_000)
        let revised = try Self.make(edited.storage.compositions, budget: &editedBudget)
        #expect(original.layerContent == [[true]] && revised.layerContent == original.layerContent)
        #expect(edited.storage === file.storage)
        #expect(try edited.text(at: 0).text == "B")
    }

    /// Null与隐藏层照原始数量计入Vector候选；合法定义ID0不能误当运行时assetID0。
    @Test func inactiveNullAndZeroDefinitionStillQualify() throws {
        let first = SceneFixtures.layer(1, active: false)
        let second = SceneFixtures.layer(2)
        var budget = FramePlanBudget(limit: 1_000_000)
        let result = try Self.make([SceneFixtures.composition(0, layers: [first, second])], budget: &budget)
        #expect(result.layerContent == [[false, false]])
        #expect(result.hasImageContent == [false] && result.vector == [true])
    }

    /// 图片在inactive子层、共享子定义或不可达定义中仍须传播；媒体子定义也算图片内容。
    @Test func hiddenNestedImagesAndMediaDisqualifyVector() throws {
        let image = try SceneFixtures.composition(3, layers: [SceneFixtures.layer(31, active: false, content: .image(1))])
        let middle = try SceneFixtures.composition(2, layers: [SceneFixtures.layer(21, active: false,
            content: .precomposition(id: 3, startFrame: 0))])
        let root = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(11, content: .precomposition(id: 2, startFrame: 0)),
            SceneFixtures.layer(12, content: .precomposition(id: 2, startFrame: 0))])
        let blank = SourceBitmapFrame(isKeyframe: true, patches: [])
        let sequence = SourceBitmapSequence(identity: try DocumentIdentity(data: Data("picture media".utf8)),
            width: 2, height: 1, frameRate: 30, frames: [blank], starts: [0], maximumPatchBytes: 0)
        let bitmap = try SourceBitmapComposition(sequences: [sequence], frameRate: 30)
        let media = SourceComposition(id: 4, size: try PAGSize(width: 100, height: 100), durationFrames: 30,
            frameRate: 30, background: SceneColor(red: 0, green: 0, blue: 0), layers: [], bitmap: bitmap)
        let mediaRoot = try SceneFixtures.composition(5, layers: [
            SceneFixtures.layer(51, content: .precomposition(id: 4, startFrame: 0)), SceneFixtures.layer(52)])
        var budget = FramePlanBudget(limit: 1_000_000)
        let result = try Self.make([root, mediaRoot, media, middle, image], budget: &budget)
        #expect(result.hasImageContent == [true, true, true, true, true])
        #expect(result.vector == [false, false, false, false, false])
        #expect(result.layerContent.allSatisfy { $0.allSatisfy { !$0 } })
    }

    /// 内容全静态、多层且无图片时才请求额外Vector Picture；相邻静态段不能冒充完整。
    @Test func vectorRequiresOneCompleteRangeAndMultipleRawLayers() throws {
        let complete = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(11), SceneFixtures.layer(12)])
        let split = try SceneFixtures.composition(2, layers: [SceneFixtures.layer(21, start: 5, duration: 20),
            SceneFixtures.layer(22)])
        var budget = FramePlanBudget(limit: 1_000_000)
        let result = try Self.make([complete, split], budget: &budget)
        #expect(result.vector == [true, false])
    }

    /// 预算失败及预取消不能返回半张资格表；相同不可变定义可被并发独立分析。
    @Test func budgetCancellationAndConcurrentAnalysis() async throws {
        let source = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1), SceneFixtures.layer(2)])
        let indices: [UInt32: Int] = [1: 0]
        var rangeBudget = FramePlanBudget(limit: 1_000_000)
        let ranges = try VectorStaticRanges.make(compositions: [source], indices: indices, budget: &rangeBudget)
        var tiny = FramePlanBudget(limit: 95)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try PictureCandidates.make(compositions: [source], indices: indices, vectorRanges: ranges, budget: &tiny)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var budget = FramePlanBudget(limit: 1_000_000)
                    let value = try PictureCandidates.make(compositions: [source], indices: indices,
                                                           vectorRanges: ranges, budget: &budget)
                    #expect(value.vector == [true])
                }
            }
            try await group.waitForAll()
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var budget = FramePlanBudget(limit: 1_000_000)
            return try PictureCandidates.make(compositions: [], indices: [:], vectorRanges: [], budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 候选入口先计算③b定义范围，再使用相同源索引；不展开实例也不触碰Picture状态。
    private static func make(_ compositions: [SourceComposition], budget: inout FramePlanBudget) throws -> PictureCandidates {
        let indices = Dictionary(uniqueKeysWithValues: compositions.enumerated().map { ($0.element.id, $0.offset) })
        let ranges = try VectorStaticRanges.make(compositions: compositions, indices: indices, budget: &budget)
        return try PictureCandidates.make(compositions: compositions, indices: indices,
                                          vectorRanges: ranges, budget: &budget)
    }
}
