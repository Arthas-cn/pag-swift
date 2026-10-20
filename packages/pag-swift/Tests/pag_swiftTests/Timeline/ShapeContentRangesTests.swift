import Testing
@testable import pag_swift

/// 验证内容轨道与外层变换的职责边界、全部字段、源时间坐标及资源限制。
struct ShapeContentRangesTests {
    /// 每条轨道单独动画都扣除20..<40；零opacity、零宽度、空路径和Polygon内属性同样参与。
    @Test(arguments: ShapeRangeFixtures.cases)
    func everyPropertyParticipates(family: String, field: Int) throws {
        let element = try ShapeRangeFixtures.element(family, selected: field)
        #expect(try ShapeRangeFixtures.ranges([element]).ranges == [0...19, 40...99])
        let constant = try ShapeRangeFixtures.element(family, selected: -1)
        #expect(try ShapeRangeFixtures.ranges([constant]).ranges == [0...99])
    }

    /// 外层变换、timeRemap、父引用和active不属于Shape内容变化；内部opacity轨道则属于内容。
    @Test func outerLayerPropertiesDoNotContaminateContentRanges() throws {
        let opacity: SourceProperty<UInt8> = try ShapeRangeFixtures.property(0, index: 0, selected: 0)
        let point: SourceProperty<ScenePoint> = try ShapeRangeFixtures.property(.zero, index: 0, selected: 0)
        let scalar = try ShapeRangeFixtures.property(0.0, index: 0, selected: 0)
        let transform = SourceTransformProperties(anchor: point, position: .combined(point), scale: point,
                                                   rotation: scalar, opacity: opacity)
        let elements = [ShapePropertyFixtures.rectangle(), ShapePropertyFixtures.fill()]
        let layer = SourceLayer(id: 1, name: "outer", parentID: 99, startFrame: 10, durationFrames: 80,
            isActive: false, transform: transform, content: .shape(elements),
            timing: .init(stretchNumerator: 1, stretchDenominator: 1, timeRemap: scalar))
        var budget = FramePlanBudget(limit: 1_000_000)
        #expect(try ShapeContentRanges.make(for: layer, budget: &budget).ranges == [0...79])
        let nested = SourceShape.group(ShapePropertyFixtures.group(opacity: opacity), elements)
        #expect(try ShapeRangeFixtures.ranges([nested], start: 10, duration: 80).ranges == [0...9, 30...79])
    }

    /// 父合成坐标排除后才减层起点，动画全在可见期外时仍为完整内容静态。
    @Test func parentTimeIsLocalizedAfterExclusion() throws {
        let element = try ShapeRangeFixtures.element("fill", selected: 1)
        #expect(try ShapeRangeFixtures.ranges([element], start: 10, duration: 80).ranges == [0...9, 30...79])
        #expect(try ShapeRangeFixtures.ranges([element], start: 50, duration: 20).ranges == [0...19])
        #expect(try ShapeRangeFixtures.ranges([], start: -100, duration: 1).ranges == [0...0])
        #expect(try ShapeRangeFixtures.ranges([], start: .min, duration: 100).ranges == [0...99])
        #expect(try ShapeRangeFixtures.ranges([], start: .max, duration: 1).ranges == [0...0])
    }

    /// 多层组先合并所有轨道的变化范围；同值Hold仍保留完整期内的静态段边界。
    @Test func nestedGroupsAccumulateTracks() throws {
        let first = try ShapeRangeFixtures.element("fill", selected: 0)
        let second: SourceProperty<UInt8> = try ShapeRangeFixtures.property(0, index: 0, selected: 0, start: 60, end: 80)
        let hold = try SourceProperty<Double>(keyframes: [SourceKeyframe(startFrame: 45, endFrame: 55,
            startValue: 0, endValue: 0, easing: .hold, spatialCurve: nil)])
        let nested = SourceShape.group(ShapePropertyFixtures.group(opacity: second), [first,
            .group(ShapePropertyFixtures.group(rotation: hold), [])])
        #expect(try ShapeRangeFixtures.ranges([nested]).ranges == [0...19, 40...44, 45...54, 55...59, 80...99])
    }

    /// 64级子列表可遍历，超过限制仍失败，即使此前轨道已使静态范围为空。
    @Test func depthValidationSurvivesEmptyRanges() throws {
        var elements: [SourceShape] = []
        for _ in 0..<64 { elements = [.group(ShapePropertyFixtures.group(), elements)] }
        #expect(try ShapeRangeFixtures.ranges(elements).ranges == [0...99])
        elements = [.group(ShapePropertyFixtures.group(), elements)]
        let all: SourceProperty<UInt8> = try ShapeRangeFixtures.property(0, index: 0, selected: 0, start: 0, end: 100)
        let prefix = ShapePropertyFixtures.fill(opacity: all)
        #expect(throws: PAGError.resourceLimitExceeded("maximumShapeDepth")) {
            try ShapeRangeFixtures.ranges([prefix] + elements)
        }
    }

    /// 无元素仍包含初始区间、列表访问与局部化成本；差一字节及非Shape输入均明确失败。
    @Test func exactBudgetAndInvalidContent() throws {
        let layer = SceneFixtures.layer(1, start: 10, duration: 80, content: .shape([]))
        var exact = FramePlanBudget(limit: 160)
        #expect(try ShapeContentRanges.make(for: layer, budget: &exact).ranges == [0...79])
        #expect(exact.used == 160)
        var small = FramePlanBudget(limit: 159)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try ShapeContentRanges.make(for: layer, budget: &small)
        }
        var budget = FramePlanBudget(limit: 1_000_000)
        #expect(throws: PAGError.self) { try ShapeContentRanges.make(for: SceneFixtures.layer(1), budget: &budget) }
        // 常量Fill仍额外消耗一个元素和两条属性的访问成本，不能在isAnimated=false时漏计。
        let constant = SceneFixtures.layer(1, content: .shape([ShapePropertyFixtures.fill()]))
        var propertyBudget = FramePlanBudget(limit: 256)
        #expect(try ShapeContentRanges.make(for: constant, budget: &propertyBudget).ranges == [0...29])
        #expect(propertyBudget.used == 256)
    }

    /// 内容分析可以并发复用同一不可变源层；空Shape也响应预取消。
    @Test func concurrentAnalysisAndCancellation() async throws {
        let layer = SceneFixtures.layer(1, duration: 100, content: .shape([try ShapeRangeFixtures.element("stroke", selected: 12)]))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    var budget = FramePlanBudget(limit: 1_000_000)
                    let result = try ShapeContentRanges.make(for: layer, budget: &budget)
                    #expect(result.ranges == [0...19, 40...99])
                }
            }
            try await group.waitForAll()
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ShapeRangeFixtures.ranges([])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
