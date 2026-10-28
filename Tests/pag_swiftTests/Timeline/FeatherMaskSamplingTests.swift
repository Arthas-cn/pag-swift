import Testing
@testable import pag_swift

/// 羽化分支的整层选择、完整测量列表、首项身份和逐帧属性采样；暂不验证GPU画面。
struct FeatherMaskSamplingTests {
    /// 普通层不产生羽化值；尾部None携带零羽化仍切换整层，并保留两项供总体测量。
    @Test func selectionUsesEntireListBeforeSkippingDraws() throws {
        let square = try ShapePathFixtures.square(20)
        let ordinary = MaskTestSupport.mask(.init(constant: square))
        var budget = FramePlanBudget(limit: 1_000_000)
        #expect(try FeatherMaskSampling.sample([ordinary], at: 0, budget: &budget) == nil)

        let none = MaskTestSupport.mask(.init(constant: square), mode: .none,
                                        feather: .init(constant: .zero))
        let sampled = try #require(try FeatherMaskSampling.sample([ordinary, none], at: 0, budget: &budget))
        #expect(sampled.items.count == 2)
        #expect(sampled.items[0].path === square)
        #expect(sampled.items[0].draw?.opacity == 255)
        #expect(sampled.items[1].draw == nil)

        // 值始终为255的显式动画仍是羽化分支，不能按当前帧数值退回普通clip。
        let animatedFull = try SourceProperty<UInt8>(keyframes: [.init(startFrame: 0, endFrame: 10,
            startValue: 255, endValue: 255, easing: .linear, spatialCurve: nil)])
        let animated = MaskTestSupport.mask(.init(constant: square), mode: .none, opacity: animatedFull)
        #expect(try FeatherMaskSampling.sample([ordinary, animated], at: 5, budget: &budget) != nil)
    }

    /// None和开放路径不占首项；仅Close虽无面积仍占首项，使后续Subtract不再翻转。
    @Test func firstSubtractUsesClosureBeforeBounds() throws {
        let square = try ShapePathFixtures.square(20)
        let open = try SourcePath(verbs: [.move], points: [.zero])
        let closeOnly = try SourcePath(verbs: [.close], points: [])
        let skipped = MaskTestSupport.mask(.init(constant: square), mode: .none,
                                           opacity: .init(constant: 254))
        let openItem = MaskTestSupport.mask(.init(constant: open), mode: .subtract)
        let subtract = MaskTestSupport.mask(.init(constant: square), mode: .subtract)
        var budget = FramePlanBudget(limit: 1_000_000)
        let first = try #require(try FeatherMaskSampling.sample([skipped, openItem, subtract],
                                                                 at: 0, budget: &budget))
        #expect(first.items[0].draw == nil && first.items[1].draw == nil)
        #expect(first.items[2].draw?.isInverted == true)

        let emptyFirst = MaskTestSupport.mask(.init(constant: closeOnly))
        let second = try #require(try FeatherMaskSampling.sample([skipped, emptyFirst, subtract],
                                                                  at: 0, budget: &budget))
        #expect(second.items[1].draw != nil)
        #expect(second.items[2].draw?.isInverted == false)

        // 零bounds的首Subtract也先消耗首项身份；第二个Subtract不应再次翻转。
        let emptySubtract = MaskTestSupport.mask(.init(constant: closeOnly), mode: .subtract)
        let third = try #require(try FeatherMaskSampling.sample([skipped, emptySubtract, subtract],
                                                                 at: 0, budget: &budget))
        #expect(third.items[1].draw?.isInverted == true)
        #expect(third.items[2].draw?.isInverted == false)
    }

    /// 同帧求出UInt8 opacity、两轴feather与Float expansion；被跳过项的扩张仍保留供测量。
    @Test func samplesAnimatedValuesAtParentFrame() throws {
        let square = try ShapePathFixtures.square(20)
        let opacity = try SourceProperty<UInt8>(keyframes: [.init(startFrame: 0, endFrame: 10,
            startValue: 100, endValue: 200, easing: .linear, spatialCurve: nil)])
        let feather = try SourceProperty<ScenePoint>(keyframes: [.init(startFrame: 0, endFrame: 10,
            startValue: .zero, endValue: ScenePoint(x: 10, y: 20), easing: .linear, spatialCurve: nil)])
        let expansion = try SourceProperty<Double>(keyframes: [.init(startFrame: 0, endFrame: 10,
            startValue: 0, endValue: 4, easing: .linear, spatialCurve: nil)])
        let active = MaskTestSupport.mask(.init(constant: square), feather: feather,
                                          opacity: opacity, expansion: expansion)
        let skipped = MaskTestSupport.mask(.init(constant: square), mode: .none,
                                           expansion: .init(constant: -3))
        var budget = FramePlanBudget(limit: 1_000_000)
        let sampled = try #require(try FeatherMaskSampling.sample([active, skipped], at: 5, budget: &budget))
        #expect(sampled.items[0].expansion == 2)
        #expect(sampled.items[0].draw?.opacity == 150)
        #expect(sampled.items[0].draw?.feather == ScenePoint(x: 5, y: 10))
        #expect(sampled.items[1].expansion == -3 && sampled.items[1].draw == nil)
    }

    /// 全列表采样按保活成本计费，精确上限成功、少一字节和预取消均不返回部分值。
    @Test func budgetAndCancellationDoNotPublishPartialValue() async throws {
        let square = try ShapePathFixtures.square(20)
        let mask = MaskTestSupport.mask(.init(constant: square), opacity: .init(constant: 128))
        var measured = FramePlanBudget(limit: 1_000_000)
        #expect(try FeatherMaskSampling.sample([mask], at: 0, budget: &measured) != nil)
        var exact = FramePlanBudget(limit: measured.used)
        #expect(try FeatherMaskSampling.sample([mask], at: 0, budget: &exact) != nil)
        var tiny = FramePlanBudget(limit: measured.used - 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try FeatherMaskSampling.sample([mask], at: 0, budget: &tiny)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var budget = FramePlanBudget(limit: 1_000_000)
            return try FeatherMaskSampling.sample([mask], at: 0, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
