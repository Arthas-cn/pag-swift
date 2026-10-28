import Testing
@testable import pag_swift

/// 两阶段路径ID作用域、paint覆盖顺序与透明组行为，不以最终面积掩盖路径拓扑错误。
struct TrimShapePreparationTests {
    /// 后出现Trim修改此前paint的同一路径，后面的新路径不参与，连续fill仍共享同一快照。
    @Test func laterModifierUpdatesEarlierPaintWithoutIncludingFuturePath() throws {
        let first = try TrimBatchFixtures.line(10), second = try TrimBatchFixtures.line(20, y: 1)
        let prepared = try TrimBatchFixtures.prepare([.path(.init(constant: first)), fill(1),
            .trimPaths(TrimBatchFixtures.source(0, 0.5)), fill(2), .path(.init(constant: second)), fill(3)])
        #expect(try TrimBatchFixtures.paints(prepared).map { try $0.material.solidColor().red } == [3, 2, 1])
        let before = try StrokeShapeFixtures.geometry(prepared, ordinal: 0)
        let after = try StrokeShapeFixtures.geometry(prepared, ordinal: 1)
        let future = try StrokeShapeFixtures.geometry(prepared, ordinal: 2)
        #expect(before === after && future.contours.count == 2)
        #expect(try TrimBatchFixtures.path(before.contours[0]).path.points.map(\.x) == [0, 5])
        #expect(future.contours[1].matches(.path(second, matrix: .identity)))
        #expect(prepared.trimBatchesByModifier[0]?.inputs.count == 1)
    }

    /// 父Trim修改此前子组的paint与路径；子组alpha仅包住自身paint，Stroke保留原paint矩阵。
    @Test func parentModifierUpdatesChildPaintAndKeepsGroupAlpha() throws {
        let path = try TrimBatchFixtures.line(20)
        let prepared = try TrimBatchFixtures.prepare([
            .group(TrimBatchFixtures.transform(x: 30, opacity: 128), [.path(.init(constant: path)), fill(1),
                .stroke(StrokeFixtures.make(order: .abovePrevious))]),
            .trimPaths(TrimBatchFixtures.source(0, 0.5)), fill(2)])
        let child = try StrokeShapeFixtures.geometry(prepared, ordinal: 0)
        let stroke = try StrokeShapeFixtures.geometry(prepared, ordinal: 1)
        let parent = try StrokeShapeFixtures.geometry(prepared, ordinal: 2)
        #expect(try TrimBatchFixtures.path(child.contours[0]) === TrimBatchFixtures.path(parent.contours[0]))
        #expect(try TrimBatchFixtures.path(child.contours[0]).path.points.map(\.x) == [30, 40])
        #expect(child.contours[0].matrix == .identity && stroke.stroke?.matrix.tx == 30)
        var budget = try GeometryBudget()
        #expect(try StrokeCenterline.make(stroke, budget: &budget).points.map(\.x) == [0, 10])
        guard case .beginOpacityGroup(let alpha) = prepared.instructions[1],
              case .endOpacityGroup = prepared.instructions.last else {
            Issue.record("父fill在下方，只有子组两次paint共享透明度")
            return
        }
        #expect(alpha == 128.0 / 255)
    }

    /// 透明子组仍执行Trim并占稳定paint/modifier序号；子组Trim只作用子组此前路径。
    @Test func invisibleGroupsAndConsecutiveModifiersKeepScope() throws {
        let path = try TrimBatchFixtures.line(20)
        let prepared = try TrimBatchFixtures.prepare([.path(.init(constant: path)), fill(1),
            .group(TrimBatchFixtures.transform(x: 30, opacity: 0), [.path(.init(constant: path)),
                .trimPaths(TrimBatchFixtures.source(0, 0.5)), fill(2)]),
            .trimPaths(TrimBatchFixtures.source(0, 0.5)), fill(3)])
        #expect(prepared.geometryIndicesByPaint.keys.sorted() == [0, 2])
        #expect(prepared.trimBatchesByModifier.keys.sorted() == [0, 1])
        let parent = try StrokeShapeFixtures.geometry(prepared, ordinal: 2)
        #expect(try parent.contours.map { try TrimBatchFixtures.path($0).path.points.map(\.x) } == [[0, 10], [30, 35]])
        let childBatch = try #require(prepared.trimBatchesByModifier[0])
        let parentBatch = try #require(prepared.trimBatchesByModifier[1])
        #expect(childBatch.inputs.count == 1 && parentBatch.inputs.count == 2)
        #expect(childBatch.outputs[0].matches(parentBatch.inputs[1]))
    }

    /// 混合Below/Above与子组插头保持旧绘制顺序，所有此前路径都读取最后裁剪后的值。
    @Test func mixedPaintOrderSurvivesTwoStages() throws {
        let path = try TrimBatchFixtures.line(10)
        let prepared = try TrimBatchFixtures.prepare([.path(.init(constant: path)), fill(1), stroke(2, .abovePrevious),
            .group(TrimBatchFixtures.transform(opacity: 128), [.path(.init(constant: path)), stroke(3, .abovePrevious), fill(4)]),
            stroke(5, .belowPrevious), .trimPaths(TrimBatchFixtures.source(0, 0.5)), fill(6), stroke(7, .abovePrevious)])
        #expect(try TrimBatchFixtures.paints(prepared).map { try $0.material.solidColor().red } == [6, 5, 4, 3, 1, 2, 7])
        for geometry in prepared.geometries {
            #expect(try geometry.contours.allSatisfy { try TrimBatchFixtures.path($0).path.points.last?.x == 5 })
        }
    }

    /// 第一遍新增Trim不得破坏Debug下64层合法边界，65层仍明确失败；后台任务也走相同调用栈。
    @Test(arguments: [64, 65]) func trimKeepsDepthBoundary(_ depth: Int) async throws {
        let path = try TrimBatchFixtures.line(10)
        var elements: [SourceShape] = [.path(.init(constant: path)), fill(1), .trimPaths(TrimBatchFixtures.source(0, 0.5))]
        for _ in 0..<depth { elements = [.group(TrimBatchFixtures.transform(x: 1), elements)] }
        let input = elements
        let task = Task { try TrimBatchFixtures.prepare(input) }
        if depth == 64 {
            let result = try await task.value
            #expect(try TrimBatchFixtures.path(result.geometries[0].contours[0]).path.points.map(\.x) == [64, 69])
        } else {
            await #expect(throws: PAGError.resourceLimitExceeded("maximumShapeDepth")) { try await task.value }
        }
    }

    /// 无路径或透明paint仍预付完整间接节点；预算失败发生在节点发布前，并回传已耗成本。
    @Test func invisibleGradientPaintNodesAreBudgeted() throws {
        let source = SourceShape.gradientStroke(GradientShapeFixtures.stroke(GradientShapeFixtures.gradient()))
        var budget = FramePlanBudget(limit: 600)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try ShapePreparation.prepare([source], budget: &budget)
        }
        #expect(budget.used == 256)
        let result = try TrimBatchFixtures.prepare([.group(TrimBatchFixtures.transform(opacity: 0), [source])])
        #expect(result.instructions.isEmpty && result.geometries.isEmpty && result.estimatedBytes > 1_024)
    }

    /// 红通道区分不同paint而不改变几何来源。
    private func fill(_ value: UInt8) -> SourceShape { .fill(color: StrokeShapeFixtures.color(value), opacity: 255) }

    /// 描边通过显式覆盖顺序参与同组前后关系。
    private func stroke(_ value: UInt8, _ order: ShapeCompositeOrder) -> SourceShape {
        .stroke(StrokeFixtures.make(color: .init(constant: StrokeShapeFixtures.color(value)), order: order))
    }
}
