import Foundation
import Testing
@testable import pag_swift

/// 按独立原始轨道与纯语义图验证定义级静态范围，不把分析结果当作Picture已启用。
struct VectorStaticRangesTests {
    /// red整体450帧全静态；fans外层Bezier位置清空子与根，区别于其Shape内容局部全静态。
    @Test func realRedAndFansMatchRawTrackGold() async throws {
        let red = try await PAGSceneDecoder.decode(PAGFixtures.data(named: "red.pag"))
        let fans = try await PAGSceneDecoder.decode(PAGFixtures.data(named: "fans.pag"))
        var redBudget = FramePlanBudget(limit: 8 * 1024 * 1024)
        let redRanges = try Self.analyze(red.storage.compositions, budget: &redBudget)
        let redIndex = try #require(red.storage.compositions.firstIndex { $0.id == 20010 })
        #expect(redRanges[redIndex].ranges == [0...449])
        var fansBudget = FramePlanBudget(limit: 8 * 1024 * 1024)
        let fansRanges = try Self.analyze(fans.storage.compositions, budget: &fansBudget)
        let childIndex = try #require(fans.storage.compositions.firstIndex { $0.id == 2076 })
        let rootIndex = try #require(fans.storage.compositions.firstIndex { $0.id == 2354 })
        #expect(fansRanges[childIndex].ranges.isEmpty)
        #expect(fansRanges[rootIndex].ranges.isEmpty)
    }

    /// inactive Null也按原始层边界分割；相邻完整片段不能合并成staticContent。
    @Test func inactiveNullStillSplitsLayerBoundaries() throws {
        let layer = SceneFixtures.layer(1, start: 5, duration: 20, active: false)
        let composition = try Self.composition(1, layers: [layer])
        var budget = FramePlanBudget(limit: 1_000_000)
        let result = try Self.analyze([composition], budget: &budget)
        #expect(result[0].ranges == [0...4, 5...24, 25...29])
        #expect(try result[0].covers(startFrame: 0, duration: 30) == false)
    }

    /// separated x与Layer timeRemap逐轨扣除；只把已选择的position分支算一次。
    @Test func separatedPositionAndTimeRemapExcludeOuterTracks() throws {
        let x = try Self.animated(10, 20)
        let y = SourceProperty<Double>(constant: 0)
        let transform = SourceTransformProperties(anchor: .init(constant: .zero),
            position: .separated(x: x, y: y), scale: .init(constant: .one),
            rotation: .init(constant: 0), opacity: .init(constant: 255))
        let timing = SourceLayerTiming(stretchNumerator: 1, stretchDenominator: 1,
                                     timeRemap: try Self.animated(22, 25))
        let layer = SourceLayer(id: 1, name: "separated", parentID: nil, startFrame: 0, durationFrames: 30,
                                isActive: true, transform: transform, content: .null, timing: timing)
        var budget = FramePlanBudget(limit: 1_000_000)
        let result = try Self.analyze([Self.composition(1, layers: [layer])], budget: &budget)
        #expect(result[0].ranges == [0...9, 20...21, 25...29])
    }

    /// combined位置及其余二维外层轨道各有独立变化窗口，必须按层顺序全部扣除。
    @Test func everyCombinedOuterTrackExcludesItsOwnWindow() throws {
        let transform = SourceTransformProperties(
            anchor: try Self.track(2, 4, value: ScenePoint.zero),
            position: .combined(try Self.track(6, 8, value: ScenePoint.zero)),
            scale: try Self.track(10, 12, value: ScenePoint.one),
            rotation: try Self.track(14, 16, value: 0.0),
            opacity: try Self.track(18, 20, value: UInt8(255)))
        let timing = SourceLayerTiming(stretchNumerator: 1, stretchDenominator: 1,
                                     timeRemap: try Self.track(22, 24, value: 0.0))
        let layer = SourceLayer(id: 1, name: "combined", parentID: nil, startFrame: 0, durationFrames: 30,
                                isActive: true, transform: transform, content: .null, timing: timing)
        var budget = FramePlanBudget(limit: 1_000_000)
        let result = try Self.analyze([Self.composition(1, layers: [layer])], budget: &budget)
        #expect(result[0].ranges == [0...1, 4...5, 8...9, 12...13, 16...17, 20...21, 24...29])
    }

    /// Shape内容轨道使用所属父合成帧；层起点只用于后续Split，不能先做局部化。
    @Test func shapeTracksUseParentFramesBeforeLayerSplit() throws {
        let fill = try ShapeRangeFixtures.element("fill", selected: 1)
        let layer = SceneFixtures.layer(1, start: 10, duration: 20, content: .shape([fill]))
        var budget = FramePlanBudget(limit: 1_000_000)
        let result = try Self.analyze([Self.composition(1, layers: [layer])], budget: &budget)
        #expect(result[0].ranges == [0...9, 10...19])
    }

    /// 每条mask的四类原始轨道即使属于None也排除Vector静态帧，并经预合成映射传到祖先。
    @Test func maskTracksExcludeVectorRangesAndPropagateToParent() throws {
        let path = try SourcePath(verbs: [.move, .line, .close],
                                  points: [.zero, ScenePoint(x: 10, y: 0)])
        let mask = MaskTestSupport.mask(try Self.track(10, 12, value: path), mode: .none,
            feather: try Self.track(2, 4, value: ScenePoint.zero),
            opacity: try Self.track(14, 16, value: UInt8(255)),
            expansion: try Self.track(6, 8, value: 0.0))
        let child = try Self.composition(1, layers: [SceneFixtures.layer(11, masks: [mask])])
        let root = try Self.composition(2, layers: [
            SceneFixtures.layer(21, content: .precomposition(id: 1, startFrame: 0)),
            SceneFixtures.layer(22)
        ])
        var budget = FramePlanBudget(limit: 1_000_000)
        let result = try Self.analyze([root, child], budget: &budget)
        let expected: [ClosedRange<Int64>] = [0...1, 4...5, 8...9, 12...13, 16...29]
        #expect(result[1].ranges == expected)
        #expect(result[0].ranges == expected)
    }

    /// 定义顺序不等于依赖顺序；两个预合成层共享子定义，不可达定义也有单独结果。
    @Test func sharedChildAndUnreachableDefinitionUsePostorder() throws {
        let child = try Self.composition(1, layers: [])
        let first = SceneFixtures.layer(11, content: .precomposition(id: 1, startFrame: 0))
        let second = SceneFixtures.layer(12, content: .precomposition(id: 1, startFrame: 0))
        let root = try Self.composition(2, layers: [first, second])
        // 定义ID0可独立存在；预合成引用0仍无效，两种身份不可混同。
        let unreachable = try Self.composition(0, layers: [SceneFixtures.layer(31, start: 5, duration: 20)])
        var budget = FramePlanBudget(limit: 1_000_000)
        let result = try Self.analyze([root, unreachable, child], budget: &budget)
        #expect(result[0].ranges == [0...29])
        #expect(result[1].ranges == [0...4, 5...24, 25...29])
        #expect(result[2].ranges == [0...29])
    }

    /// 预合成引用0即使恰有定义ID0，也按源引用语义拒绝，不能误连到该定义。
    @Test func zeroReferenceDoesNotResolveToZeroDefinition() throws {
        let zero = try Self.composition(0, layers: [])
        let root = try Self.composition(1, layers: [SceneFixtures.layer(1, content: .precomposition(id: 0, startFrame: 0))])
        var budget = FramePlanBudget(limit: 1_000_000)
        #expect(throws: PAGError.self) { try Self.analyze([zero, root], budget: &budget) }
    }

    /// 静态TextSource没有额外变化轨道，内容与Layer边界分割仍照常保留。
    @Test func staticTextUsesOnlyOuterLayerAndBoundaries() throws {
        let text = try TextFixtures.source("A")
        let layer = SceneFixtures.layer(1, start: 5, duration: 20, content: .text(text))
        var budget = FramePlanBudget(limit: 1_000_000)
        let result = try Self.analyze([Self.composition(1, layers: [layer])], budget: &budget)
        #expect(result[0].ranges == [0...4, 5...24, 25...29])
    }

    /// Bitmap/Video原始段重叠或乱序时仅关闭分析复用，不尝试合并为错误的完整段。
    @Test func overlappingMediaRangesConservativelyBecomeEmpty() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        #expect(try VectorStaticRanges.media([0...5, 5...10], budget: &budget).ranges.isEmpty)
        #expect(try VectorStaticRanges.media([8...10, 0...5], budget: &budget).ranges.isEmpty)
        #expect(try VectorStaticRanges.media([0...5, 6...10], budget: &budget).ranges == [0...5, 6...10])
        #expect(try VectorStaticRanges.media([8...10], budget: &budget).ranges == [8...10])
    }

    /// 两段源Bitmap静态窗口经低合成帧率roundf落在同一帧，定义级分析必须退空。
    @Test func roundedBitmapOverlapBecomesEmptyThroughMake() throws {
        // 时间表夹具以宽2区分非空帧，空Data只参与isEmpty判定，并非可解码WebP。
        let active = SourceBitmapFrame(isKeyframe: true, patches: [SourceBitmapPatch(
            x: 0, y: 0, width: 2, height: 1, data: Data())])
        let blank = SourceBitmapFrame(isKeyframe: false, patches: [])
        let sequence = SourceBitmapSequence(identity: try DocumentIdentity(data: Data("rounded overlap".utf8)),
            width: 2, height: 1, frameRate: 30, frames: [active, blank, active, blank, active],
            starts: [0, 0, 2, 2, 4], maximumPatchBytes: 0)
        let bitmap = try SourceBitmapComposition(sequences: [sequence], frameRate: 3)
        #expect(bitmap.staticRanges == [0...0, 0...0])
        let source = SourceComposition(id: 1, size: try PAGSize(width: 100, height: 100), durationFrames: 30,
            frameRate: 3, background: SceneColor(red: 0, green: 0, blue: 0), layers: [], bitmap: bitmap)
        var budget = FramePlanBudget(limit: 1_000_000)
        #expect(try Self.analyze([source], budget: &budget)[0].ranges.isEmpty)
    }

    /// 媒体静态端点可越过标称时长；定义表保留原端点，父预合成只保留实际安全采样。
    @Test func mediaBeyondDurationPropagatesThroughPrecomposition() throws {
        // 这里只测纯时间表：宽2让首帧不满足上游空帧谓词，空Data不是可解码WebP输入。
        let active = SourceBitmapFrame(isKeyframe: true, patches: [SourceBitmapPatch(
            x: 0, y: 0, width: 2, height: 1, data: Data())])
        let blank = SourceBitmapFrame(isKeyframe: false, patches: [])
        let sequence = SourceBitmapSequence(identity: try DocumentIdentity(data: Data("static overflow".utf8)),
            width: 2, height: 1, frameRate: 30, frames: [active] + Array(repeating: blank, count: 10),
            starts: Array(repeating: 0, count: 11), maximumPatchBytes: 0)
        let bitmap = try SourceBitmapComposition(sequences: [sequence], frameRate: 30)
        let media = SourceComposition(id: 1, size: try PAGSize(width: 100, height: 100), durationFrames: 10,
            frameRate: 30, background: SceneColor(red: 0, green: 0, blue: 0), layers: [], bitmap: bitmap)
        let root = try Self.composition(2, layers: [SceneFixtures.layer(2, start: 5, duration: 10,
            content: .precomposition(id: 1, startFrame: 5))])
        var budget = FramePlanBudget(limit: 1_000_000)
        let result = try Self.analyze([root, media], budget: &budget)
        #expect(result[1].ranges == [0...10])
        #expect(result[0].ranges == [0...4, 5...14, 15...29])
    }

    /// 第一层使父范围全空后，后续层只计图遍历与层访问，不得继续访问其Shape内容。
    @Test func emptyParentStopsLaterLayerAnalysis() throws {
        let transform = SourceTransformProperties(anchor: try Self.track(0, 30, value: ScenePoint.zero),
            position: .combined(.init(constant: .zero)), scale: .init(constant: .one),
            rotation: .init(constant: 0), opacity: .init(constant: 255))
        let first = SceneFixtures.layer(1, transform: transform)
        let second = SceneFixtures.layer(2, content: .shape([ShapePropertyFixtures.fill()]))
        var singleBudget = FramePlanBudget(limit: 1_000_000)
        let single = try Self.analyze([Self.composition(1, layers: [first])], budget: &singleBudget)
        var bothBudget = FramePlanBudget(limit: 1_000_000)
        let both = try Self.analyze([Self.composition(1, layers: [first, second])], budget: &bothBudget)
        #expect(single[0].ranges.isEmpty && both[0].ranges.isEmpty)
        #expect(bothBudget.used - singleBudget.used == 64)
    }

    /// 共享不可变定义支持并发；预算不足与空数组预取消都不能发布部分表。
    @Test func budgetCancellationAndConcurrentReuse() async throws {
        let source = try Self.composition(1, layers: [SceneFixtures.layer(1)])
        var tiny = FramePlanBudget(limit: 31)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try Self.analyze([source], budget: &tiny)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    var budget = FramePlanBudget(limit: 1_000_000)
                    let result = try Self.analyze([source], budget: &budget)
                    #expect(result[0].ranges == [0...29])
                }
            }
            try await group.waitForAll()
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var budget = FramePlanBudget(limit: 1_000_000)
            return try Self.analyze([], budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 从定义ID建立引用索引并调用分析，不经公开实例树重排编码层。
    private static func analyze(_ compositions: [SourceComposition], budget: inout FramePlanBudget) throws -> [StaticFrameRanges] {
        let indices = Dictionary(uniqueKeysWithValues: compositions.enumerated().map { ($0.element.id, $0.offset) })
        return try VectorStaticRanges.make(compositions: compositions, indices: indices, budget: &budget)
    }

    /// 创建30帧的纯语义定义，允许按调用顺序安排共享与不可达引用。
    private static func composition(_ id: UInt32, layers: [SourceLayer]) throws -> SourceComposition {
        SourceComposition(id: id, size: try PAGSize(width: 100, height: 100), durationFrames: 30,
            frameRate: 30, background: SceneColor(red: 0, green: 0, blue: 0), layers: layers)
    }

    /// 明确创建同值Linear轨道，静态分析仍必须按时间排除它。
    private static func animated(_ start: Int64, _ end: Int64) throws -> SourceProperty<Double> {
        try SourceProperty(keyframes: [SourceKeyframe(startFrame: start, endFrame: end,
            startValue: 0, endValue: 0, easing: .linear, spatialCurve: nil)])
    }

    /// 为不同值类型构造同值动画；即使值不变，源区间仍会阻断静态复用。
    private static func track<Value: Sendable>(_ start: Int64, _ end: Int64, value: Value) throws -> SourceProperty<Value> {
        try SourceProperty(keyframes: [SourceKeyframe(startFrame: start, endFrame: end,
            startValue: value, endValue: value, easing: .linear, spatialCurve: nil)])
    }
}
