import Testing
@testable import pag_swift

/// Repeater在形状两阶段准备中克隆完整此前组，检查几何、paint和清组行为。
struct ShapeRepeaterTests {
    /// 两条不同路径及各自paint都要复制，第二份路径和paint矩阵整体平移40。
    @Test func clonesAllPreviousPathsAndPaints() throws {
        let first = ShapePropertyFixtures.rectangle(position: .init(constant: ScenePoint(x: 10, y: 20)))
        let second = ShapePropertyFixtures.rectangle(position: .init(constant: ScenePoint(x: 30, y: 20)))
        let elements: [SourceShape] = [first, ShapePropertyFixtures.fill(), second,
            ShapePropertyFixtures.fill(color: .init(constant: SceneColor(red: 0, green: 0, blue: 255))),
            .repeater(repeater(copies: 2, shift: 40))]
        let prepared = try ShapePropertyFixtures.prepare(elements)
        #expect(ShapePropertyFixtures.paints(prepared).count == 4)
        let x = prepared.geometries.flatMap(\.contours).map(\.matrix.tx)
        #expect(x.contains(0) && x.contains(40))
    }

    /// 零份数消除已有paint，负份数保留原组，不把已有路径误作空输入。
    @Test func zeroClearsAndNegativeKeepsPreviousGroup() throws {
        let prefix: [SourceShape] = [ShapePropertyFixtures.rectangle(), ShapePropertyFixtures.fill()]
        let cleared = try ShapePropertyFixtures.prepare(prefix + [.repeater(repeater(copies: 0))])
        let kept = try ShapePropertyFixtures.prepare(prefix + [.repeater(repeater(copies: -1))])
        #expect(ShapePropertyFixtures.paints(cleared).isEmpty)
        #expect(ShapePropertyFixtures.paints(kept).count == 1)
    }

    /// 先完成Trim再复制，两个克隆须保留同一裁剪曲线长度，只相差重复位移。
    @Test func clonesAlreadyTrimmedCurveWithoutRemeasuring() throws {
        let trim = SourceTrimPaths(start: .init(constant: 0), end: .init(constant: 0.5),
                                   offset: .init(constant: 0), mode: .simultaneously)
        let prepared = try ShapePropertyFixtures.prepare([
            ShapePropertyFixtures.rectangle(), ShapePropertyFixtures.fill(),
            .trimPaths(trim), .repeater(repeater(copies: 2, shift: 40))
        ])
        let paths = prepared.geometries.compactMap { geometry -> StrokePath? in
            guard case .trimmed(let value) = geometry.contours.first else { return nil }
            return value.path
        }
        #expect(paths.count == 2)
        if paths.count == 2 {
            #expect(paths[0].verbs == paths[1].verbs)
            for (first, second) in zip(paths[0].points, paths[1].points) {
                #expect(abs(second.x - first.x - 40) < 0.0001)
                #expect(abs(second.y - first.y) < 0.0001)
            }
        }
    }

    /// 用源语义值构造当前测试的份数和位置，默认轨道仍按上游配置显式保存。
    private func repeater(copies: Double, shift: Double = 0) -> SourceRepeater {
        SourceRepeater(order: .below, copies: .init(constant: copies), offset: .init(constant: 0),
            anchor: .init(constant: .zero), position: .init(constant: ScenePoint(x: shift, y: 0)),
            scale: .init(constant: .one), rotation: .init(constant: 0),
            startOpacity: .init(constant: 255), endOpacity: .init(constant: 255))
    }
}
