import Testing
@testable import pag_swift

/// 验证预合成正向候选只在实际反向采样仍属于同一子静态段时复用。
struct PrecompositionStaticRangesTests {
    /// 降帧率让相邻子段映成重叠父端点时，父帧2必须属于第二段，不能折到帧0。
    @Test func overlappingMappedSegmentsStayDistinct() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        let parent = try StaticFrameRanges([0...3], budget: &budget)
        let child = try StaticFrameRanges([0...15, 16...31], budget: &budget)
        let actual = try PrecompositionStaticRanges.intersectingContent(parent, child: child,
            childDuration: 32, parentRate: 3, childRate: 30, compositionStart: 0,
            layerStart: 0, layerDuration: 4, budget: &budget)
        #expect(actual.ranges == [0...1, 2...3])
        #expect(try actual.representativeFrame(for: 2, budget: &budget) == 2)
        #expect(try actual.covers(startFrame: 0, duration: 4) == false)
    }

    /// 即使正向映射不重叠，父帧1实际采到子10时也不能复用子[0,5]。
    @Test func forwardCandidateCannotHideDynamicSample() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        let parent = try StaticFrameRanges([0...1], budget: &budget)
        let child = try StaticFrameRanges([0...5], budget: &budget)
        let actual = try PrecompositionStaticRanges.intersectingContent(parent, child: child,
            childDuration: 32, parentRate: 3, childRate: 30, compositionStart: 0,
            layerStart: 0, layerDuration: 2, budget: &budget)
        #expect(actual.ranges.isEmpty)
    }

    /// 父帧率高于子帧率时多个父帧采同一子帧，仍按正向候选保守保留端点。
    @Test func higherParentRateHasFlatReverseSamples() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        let parent = try StaticFrameRanges([0...30], budget: &budget)
        let child = try StaticFrameRanges([1...2], budget: &budget)
        let actual = try PrecompositionStaticRanges.intersectingContent(parent, child: child,
            childDuration: 3, parentRate: 30, childRate: 3, compositionStart: 0,
            layerStart: 0, layerDuration: 31, budget: &budget)
        #expect(actual.ranges == [10...20])
        #expect(try actual.representativeFrame(for: 15, budget: &budget) == 10)
    }

    /// 同帧率时头部、内容、尾部保持三个相邻段，不能合并为虚假的完整静态合成。
    @Test func outsideLayerSegmentsRemainSeparate() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        let parent = try StaticFrameRanges([0...29], budget: &budget)
        let child = try StaticFrameRanges([0...9], budget: &budget)
        let actual = try PrecompositionStaticRanges.intersectingContent(parent, child: child,
            childDuration: 10, parentRate: 30, childRate: 30, compositionStart: 10,
            layerStart: 10, layerDuration: 10, budget: &budget)
        #expect(actual.ranges == [0...9, 10...19, 20...29])
        #expect(try actual.covers(startFrame: 0, duration: 30) == false)
    }

    /// 二分只检查父亲现有片段；已有的动态空洞不能被子范围或层外补段重新填充。
    @Test func parentHolesRemainExcluded() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        let parent = try StaticFrameRanges([0...4, 8...15], budget: &budget)
        let child = try StaticFrameRanges([0...9], budget: &budget)
        let actual = try PrecompositionStaticRanges.intersectingContent(parent, child: child,
            childDuration: 16, parentRate: 30, childRate: 30, compositionStart: 0,
            layerStart: 0, layerDuration: 16, budget: &budget)
        #expect(actual.ranges == [0...4, 8...9])
    }

    /// 负合成起点与层可见起点分别消费，不能把二者叠加减两次。
    @Test func negativeCompositionStartRemainsIndependent() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        let parent = try StaticFrameRanges([-10...10], budget: &budget)
        let child = try StaticFrameRanges([0...9], budget: &budget)
        let actual = try PrecompositionStaticRanges.intersectingContent(parent, child: child,
            childDuration: 10, parentRate: 24, childRate: 24, compositionStart: -5,
            layerStart: -5, layerDuration: 10, budget: &budget)
        #expect(actual.ranges == [-5...4, 5...10])
    }

    /// 媒体子静态段可越过标称时长；裁剪与实际子帧钳制后仍保留安全的父段。
    @Test func childRangeMayExtendBeyondDuration() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        let parent = try StaticFrameRanges([0...9], budget: &budget)
        let child = try StaticFrameRanges([8...10], budget: &budget)
        let actual = try PrecompositionStaticRanges.intersectingContent(parent, child: child,
            childDuration: 10, parentRate: 30, childRate: 30, compositionStart: 0,
            layerStart: 0, layerDuration: 10, budget: &budget)
        #expect(actual.ranges == [8...9])
    }

    /// 子表为空仍可在层外保留多帧静态；源码不会保留恰好一帧的尾段。
    @Test func emptyChildKeepsOnlySourceOutsideRules() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        let parent = try StaticFrameRanges([0...10], budget: &budget)
        let empty = try StaticFrameRanges([], budget: &budget)
        let outside = try PrecompositionStaticRanges.intersectingContent(parent, child: empty,
            childDuration: 5, parentRate: 30, childRate: 30, compositionStart: 0,
            layerStart: 3, layerDuration: 5, budget: &budget)
        #expect(outside.ranges == [0...2, 8...10])
        let tailPoint = try PrecompositionStaticRanges.intersectingContent(parent, child: empty,
            childDuration: 10, parentRate: 30, childRate: 30, compositionStart: 0,
            layerStart: 0, layerDuration: 10, budget: &budget)
        #expect(tailPoint.ranges.isEmpty)
    }

    /// duration=1的子内容不产生可复用段，层前后仍按源码的严格多帧规则保留。
    @Test func oneFrameContentDoesNotBecomeStaticSegment() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        let parent = try StaticFrameRanges([0...10], budget: &budget)
        let child = try StaticFrameRanges([0...0], budget: &budget)
        let actual = try PrecompositionStaticRanges.intersectingContent(parent, child: child,
            childDuration: 1, parentRate: 30, childRate: 30, compositionStart: 3,
            layerStart: 3, layerDuration: 1, budget: &budget)
        #expect(actual.ranges == [0...2, 4...10])
    }

    /// Int64最小父起点可经差值采样，不计算无法表示的负起点或跨零中点。
    @Test func minimumFrameOriginCanMapWhenDifferencesFit() throws {
        var budget = FramePlanBudget(limit: 1_000_000)
        let parent = try StaticFrameRanges([Int64.min...(Int64.min + 10)], budget: &budget)
        let child = try StaticFrameRanges([0...9], budget: &budget)
        let actual = try PrecompositionStaticRanges.intersectingContent(parent, child: child,
            childDuration: 10, parentRate: 24, childRate: 24, compositionStart: .min,
            layerStart: .min, layerDuration: 10, budget: &budget)
        #expect(actual.ranges == [Int64.min...(Int64.min + 9)])
    }

    /// 层已无父静态帧时直接短路；非法帧率、偏移溢出与预算不足必须明确失败且不改输入。
    @Test func invalidMappingAndBudgetDoNotPublishPartialRanges() throws {
        var setup = FramePlanBudget(limit: 1_000_000)
        let empty = try StaticFrameRanges([], budget: &setup)
        let child = try StaticFrameRanges([0...1], budget: &setup)
        #expect(try PrecompositionStaticRanges.intersectingContent(empty, child: child,
            childDuration: 2, parentRate: 0, childRate: 30, compositionStart: 0,
            layerStart: 0, layerDuration: 2, budget: &setup) == empty)
        let parent = try StaticFrameRanges([0...10], budget: &setup)
        #expect(throws: PAGError.self) {
            try PrecompositionStaticRanges.intersectingContent(parent, child: child,
                childDuration: 2, parentRate: 0, childRate: 30, compositionStart: 0,
                layerStart: 0, layerDuration: 2, budget: &setup)
        }
        #expect(throws: PAGError.self) {
            try PrecompositionStaticRanges.intersectingContent(parent, child: child,
                childDuration: 2, parentRate: 30, childRate: 30, compositionStart: .max,
                layerStart: 0, layerDuration: 2, budget: &setup)
        }
        var tiny = FramePlanBudget(limit: 31)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try PrecompositionStaticRanges.intersectingContent(parent, child: child,
                childDuration: 2, parentRate: 30, childRate: 30, compositionStart: 0,
                layerStart: 0, layerDuration: 2, budget: &tiny)
        }
        #expect(parent.ranges == [0...10])
    }

    /// 同一不可变输入可并发分析；预取消即使父范围为空也不得返回成功。
    @Test func sharedInputsAndEmptyCancellation() async throws {
        var setup = FramePlanBudget(limit: 1_000_000)
        let parent = try StaticFrameRanges([0...3], budget: &setup)
        let child = try StaticFrameRanges([0...15, 16...31], budget: &setup)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    var budget = FramePlanBudget(limit: 1_000_000)
                    let result = try PrecompositionStaticRanges.intersectingContent(parent, child: child,
                        childDuration: 32, parentRate: 3, childRate: 30, compositionStart: 0,
                        layerStart: 0, layerDuration: 4, budget: &budget)
                    #expect(result.ranges == [0...1, 2...3])
                }
            }
            try await group.waitForAll()
        }
        let empty = try StaticFrameRanges([], budget: &setup)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var budget = FramePlanBudget(limit: 1_000_000)
            return try PrecompositionStaticRanges.intersectingContent(empty, child: child,
                childDuration: 32, parentRate: 3, childRate: 30, compositionStart: 0,
                layerStart: 0, layerDuration: 4, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
