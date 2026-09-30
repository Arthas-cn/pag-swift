import Testing
@testable import pag_swift

/// 材料接入共同形状准备器后的完整轨道、稳定paint身份、预算及递归边界。
struct GradientShapePreparationTests {
    /// 八条轨道各自进入动态准备；颜色变化只换程序，样式变化只换几何，端点/alpha均可复用。
    @Test(arguments: 0..<8)
    func allTracksRespectSeparateIdentities(_ field: Int) throws {
        let elements = try GradientShapeFixtures.animated(field)
        var budget = FramePlanBudget(limit: 1_000_000)
        #expect(try ShapePreparation.isAnimated(elements, budget: &budget))
        let first = try ShapePropertyFixtures.prepare(elements)
        let changed = try ShapePropertyFixtures.prepare(elements, frame: 5, reuse: [first])
        #expect((first.geometries[0] === changed.geometries[0]) == (field < 4))
        #expect((first.gradientColorizersByPaint[0] === changed.gradientColorizersByPaint[0]) == (field != 2))
        let paint = try #require(ShapePropertyFixtures.paints(changed).first)
        let material = try paint.material.gradientValue()
        switch field {
        case 0: #expect(material.start == ScenePoint(x: 15, y: 10))
        case 1: #expect(material.end == ScenePoint(x: 65, y: 10))
        case 2: #expect(material.colorizer.source.colorStops[0].color == SceneColor(red: 127, green: 127, blue: 0))
        case 3: #expect(paint.opacity == 150.0 / 255)
        case 4: #expect(changed.geometries[0].stroke?.style.miterLimit == 6)
        case 5: #expect(changed.geometries[0].stroke?.style.width == 6)
        case 6: #expect(changed.geometries[0].stroke?.style.dashes?.phase == 6)
        case 7: #expect(changed.geometries[0].stroke?.style.dashes?.intervals == [6, 6])
        default: Issue.record("未知测试轨道")
        }
        let restored = try ShapePropertyFixtures.prepare(elements, reuse: [changed, first])
        #expect(restored.geometries[0] === first.geometries[0])
        #expect(restored.gradientColorizersByPaint[0] === first.gradientColorizersByPaint[0])
    }

    /// 不可见前paint不压缩源ordinal；两种fill共享快照，渐变Above仍按源覆盖顺序。
    @Test func stableOrdinalsAndMixedPaintOrdering() throws {
        let colors = GradientColorFixtures.colors()
        let fading = try GradientShapeFixtures.gradient(colors: .init(constant: colors),
            opacity: ShapePropertyFixtures.track(UInt8(255), UInt8(0)))
        let visible = GradientShapeFixtures.gradient(colors: .init(constant: colors))
        let elements: [SourceShape] = [ShapePropertyFixtures.rectangle(),
            .gradientFill(.init(compositeOrder: .abovePrevious, gradient: fading)),
            ShapePropertyFixtures.fill(), .gradientFill(.init(compositeOrder: .belowPrevious, gradient: visible))]
        let first = try ShapePropertyFixtures.prepare(elements)
        let hidden = try ShapePropertyFixtures.prepare(elements, frame: 10, reuse: [first])
        #expect(first.geometryIndicesByPaint == [0: 0, 1: 0, 2: 0])
        #expect(hidden.geometryIndicesByPaint == [1: 0, 2: 0])
        #expect(Set(hidden.gradientColorizersByPaint.keys) == [2])
        #expect(hidden.gradientColorizersByPaint[2] === first.gradientColorizersByPaint[2])
        #expect(hidden.geometries[0] === first.geometries[0])
        let paints = ShapePropertyFixtures.paints(first)
        #expect(try paints[0].material.gradientValue().colorizer === first.gradientColorizersByPaint[2])
        #expect(try paints[1].material.solidColor() == .defaultFill)
        #expect(try paints[2].material.gradientValue().colorizer === first.gradientColorizersByPaint[0])
    }

    /// 透明组仍向父paint交出带矩阵路径，组内无效材料不求值；非正宽同样先跳过材料。
    @Test func invisiblePaintsKeepContoursWithoutPreparingColors() throws {
        let invalid = SourceGradientColors(alphaStops: [], colorStops: [])
        let material = GradientShapeFixtures.gradient(colors: .init(constant: invalid))
        let source: [SourceShape] = [.group(ShapePropertyFixtures.group(position: .init(constant: ScenePoint(x: 5, y: 7)),
            opacity: .init(constant: 0)), GradientShapeFixtures.elements(material)),
            .gradientStroke(GradientShapeFixtures.stroke(material, width: .init(constant: 0))), ShapePropertyFixtures.fill()]
        let result = try ShapePropertyFixtures.prepare(source)
        #expect(result.gradientColorizersByPaint.isEmpty && result.geometryIndicesByPaint == [2: 0])
        #expect(result.geometries[0].contours[0].matrix == (try .translation(x: 5, y: 7)))
    }

    /// 渐变的大载荷不会重新撑大递归帧；64层在Debug可用，65层准备和分类均失败。
    @Test(arguments: [false, true])
    func gradientsPreserveDepthBoundary(_ stroke: Bool) throws {
        var elements = GradientShapeFixtures.elements(GradientShapeFixtures.gradient(), stroke: stroke)
        for _ in 0..<64 { elements = [.group(ShapePropertyFixtures.group(), elements)] }
        #expect(try ShapePropertyFixtures.prepare(elements).gradientColorizersByPaint.count == 1)
        var budget = FramePlanBudget(limit: 1_000_000)
        #expect(try ShapePreparation.isAnimated(elements, budget: &budget) == false)
        elements = [.group(ShapePropertyFixtures.group(), elements)]
        #expect(throws: PAGError.resourceLimitExceeded("maximumShapeDepth")) { try ShapePropertyFixtures.prepare(elements) }
        #expect(throws: PAGError.resourceLimitExceeded("maximumShapeDepth")) {
            try ShapePreparation.isAnimated(elements, budget: &budget)
        }
    }

    /// 暖命中仍计颜色程序保活成本；不足预算和预取消不能返回部分采样。
    @Test func cachedMaterialsRemainBudgetedAndCancellable() async throws {
        let elements = GradientShapeFixtures.elements(GradientShapeFixtures.gradient())
        let first = try ShapePropertyFixtures.prepare(elements)
        let warm = try ShapePropertyFixtures.prepare(elements, reuse: [first])
        var budget = FramePlanBudget(limit: warm.estimatedBytes - 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try ShapePreparation.prepare(elements, reusing: [first], budget: &budget)
        }
        #expect(budget.used > 512)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ShapePropertyFixtures.prepare(elements, reuse: [first])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
