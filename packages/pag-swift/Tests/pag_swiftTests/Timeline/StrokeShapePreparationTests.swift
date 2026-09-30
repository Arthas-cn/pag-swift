import Testing
@testable import pag_swift

/// 描边准备的源顺序、组边界、源帧与身份；只构造语义场景，不提前打开tag21。
struct StrokeShapePreparationTests {
    /// Below插头、Above追加、子组插头分别作用于已有内容，不能把整个paint列表简单反转。
    @Test func mixedPaintOrdersPreserveGroupsAndPathOrder() throws {
        let prepared = try StrokeShapeFixtures.prepare([
            StrokeShapeFixtures.rectangle(), .fill(color: color(1), opacity: 255), stroke(2, order: .abovePrevious),
            .group(StrokeShapeFixtures.transform(x: 30, opacity: 128), [StrokeShapeFixtures.rectangle(),
                stroke(3, order: .abovePrevious), .fill(color: color(4), opacity: 255)]),
            stroke(5), .fill(color: color(6), opacity: 255), stroke(7, order: .abovePrevious)
        ])
        let paints = StrokeShapeFixtures.paints(prepared)
        #expect(try paints.map { try $0.material.solidColor().red } == [6, 5, 4, 3, 1, 2, 7])
        try #require(prepared.instructions.count == 9)
        guard case .beginOpacityGroup(let alpha) = prepared.instructions[2],
              case .endOpacityGroup = prepared.instructions[5] else {
            Issue.record("只有子组的两次paint应被整体alpha包住")
            return
        }
        #expect(alpha == 128.0 / 255)
        let last = try StrokeShapeFixtures.geometry(prepared, ordinal: 6)
        #expect(last.contours.map(\.matrix.tx) == [0, 30])
        #expect(last.stroke?.matrix == .identity)
        #expect(try StrokeShapeFixtures.geometry(prepared, ordinal: 2).stroke?.matrix.tx == 30)
        #expect(prepared.geometryIndicesByPaint.count == 7)
    }

    /// 无路径、透明组、零alpha和零width仍占源ordinal；它们不清空供外层paint使用的路径。
    @Test func invisiblePaintsKeepStableOrdinalsAndCenterlines() throws {
        let prepared = try StrokeShapeFixtures.prepare([
            .fill(color: color(1), opacity: 255),
            .group(StrokeShapeFixtures.transform(x: 30, opacity: 0), [StrokeShapeFixtures.rectangle(),
                .fill(color: color(2), opacity: 255), stroke(3)]),
            .stroke(StrokeFixtures.make(opacity: .init(constant: 0))),
            .stroke(StrokeFixtures.make(width: .init(constant: 0))),
            .fill(color: color(4), opacity: 255), stroke(5)
        ])
        #expect(prepared.geometryIndicesByPaint == [5: 0, 6: 1])
        #expect(try StrokeShapeFixtures.paints(prepared).map { try $0.material.solidColor().red } == [5, 4])
        #expect(prepared.geometries.allSatisfy { $0.contours.count == 1 && $0.contours[0].matrix.tx == 30 })
        #expect(prepared.geometries[1].stroke?.matrix == .identity)
    }

    /// 颜色/宽度/alpha按同一个源合成帧求值；paint保留当前组矩阵而不提前构造outline。
    @Test func strokeTracksUseCompositionTimeAndCurrentPaintMatrix() throws {
        let source = StrokeFixtures.make(width: try StrokeFixtures.track(2.0, 6),
            color: try StrokeFixtures.track(color(0), color(100)), opacity: try StrokeFixtures.track(UInt8(100), UInt8(200)))
        let group = SourceShapeTransform(base: SourceTransform(anchor: .zero, position: ScenePoint(x: 10, y: 20),
            scale: ScenePoint(x: 3, y: 2), rotation: 0, opacity: 255), skew: 0, skewAxis: 0)
        let prepared = try StrokeShapeFixtures.prepare([.group(group, [StrokeShapeFixtures.rectangle(), .stroke(source)])], frame: 5)
        let paint = try #require(StrokeShapeFixtures.paints(prepared).first)
        let geometry = try StrokeShapeFixtures.geometry(prepared, ordinal: 0)
        #expect(try paint.material.solidColor() == color(50) && paint.opacity == 150.0 / 255)
        #expect(geometry.stroke?.style.width == 4)
        #expect(geometry.stroke?.matrix.a == 3 && geometry.stroke?.matrix.d == 2)
        #expect(geometry.stroke?.matrix.tx == 10 && geometry.stroke?.matrix.ty == 20)
    }

    /// 每条stroke轨道独立动画都使所属层动态，包括不可见子组；静态stroke不误判为动画。
    @Test func everyStrokeTrackAffectsAnimationClassification() throws {
        let scalar = try StrokeFixtures.track(2.0, 4)
        let variants = [StrokeFixtures.make(width: scalar), StrokeFixtures.make(miter: scalar),
            StrokeFixtures.make(color: try StrokeFixtures.track(color(0), color(100))),
            StrokeFixtures.make(opacity: try StrokeFixtures.track(UInt8(0), UInt8(255))),
            StrokeFixtures.make(dashes: try SourceDashes(offset: scalar, intervals: [.init(constant: 10)])),
            StrokeFixtures.make(dashes: try SourceDashes(offset: .init(constant: 0), intervals: [scalar]))]
        var budget = FramePlanBudget(limit: 1_000_000)
        for source in variants {
            #expect(try ShapePreparation.isAnimated([.group(StrokeShapeFixtures.transform(opacity: 0), [.stroke(source)])], budget: &budget))
        }
        #expect(try !ShapePreparation.isAnimated([.stroke(StrokeFixtures.make())], budget: &budget))
    }

    /// 多于四个候选在准备前拒绝；前缀完成后资源失败仍将已耗预算回传给调用方。
    @Test func candidateBoundAndFailedWorkAreAccounted() throws {
        let old = try StrokeShapeFixtures.prepare([StrokeShapeFixtures.rectangle(), stroke(1)])
        var emptyBudget = FramePlanBudget(limit: 1_000_000)
        #expect(throws: PAGError.invalidArgument("shapeReuseCandidates")) {
            try ShapePreparation.prepare([], reusing: Array(repeating: old, count: 5), budget: &emptyBudget)
        }
        #expect(emptyBudget.used == 0)
        var limited = FramePlanBudget(limit: 2_000)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try ShapePreparation.prepare([StrokeShapeFixtures.rectangle(), stroke(1), stroke(2), stroke(3)], budget: &limited)
        }
        #expect(limited.used > 512 && limited.used <= 2_000)
    }

    /// 用红通道编号区分源paint顺序，不参与任何几何期望生成。
    private func color(_ value: UInt8) -> SceneColor { StrokeShapeFixtures.color(value) }

    /// 默认Below实线，调用点显式标出需要追加到上方的paint。
    private func stroke(_ value: UInt8, order: ShapeCompositeOrder = .belowPrevious) -> SourceShape {
        .stroke(StrokeFixtures.make(color: .init(constant: color(value)), order: order))
    }
}

/// 准备与复用测试的纯语义输入辅助；实际顺序和对象身份均由正式准备器生成。
enum StrokeShapeFixtures {
    /// 用红通道标识paint，颜色与几何保持分离。
    static func color(_ value: UInt8) -> SceneColor { SceneColor(red: value, green: 0, blue: 0) }

    /// 中心为原点、边长20的静态矩形，能够同时作为fill与stroke中心线。
    static func rectangle() -> SourceShape {
        .rectangle(reversed: false, size: ScenePoint(x: 20, y: 20), position: .zero, roundness: 0)
    }

    /// 创建静态组变换；透明组依旧参与源paint身份遍历。
    static func transform(x: Double = 0, opacity: UInt8 = 255) -> SourceShapeTransform {
        SourceShapeTransform(base: SourceTransform(anchor: .zero, position: ScenePoint(x: x, y: 0),
            scale: .one, rotation: 0, opacity: opacity), skew: 0, skewAxis: 0)
    }

    /// 在独立预算内准备一帧；reuse必须满足生产入口的同源模板前置条件。
    static func prepare(_ elements: [SourceShape], frame: Int64 = 0,
                        reuse: [PreparedShapeLayer] = []) throws -> PreparedShapeLayer {
        var budget = FramePlanBudget(limit: 1_000_000)
        return try ShapePreparation.prepare(elements, at: frame, reusing: reuse, budget: &budget)
    }

    /// 保留真实指令顺序，仅去掉组边界以便断言paint属性。
    static func paints(_ layer: PreparedShapeLayer) -> [ShapePaint] {
        layer.instructions.compactMap { if case .fill(let paint) = $0 { paint } else { nil } }
    }

    /// 通过稳定源ordinal取得实际几何；缺失映射使测试明确失败。
    static func geometry(_ layer: PreparedShapeLayer, ordinal: Int) throws -> ShapeGeometry {
        let index = try #require(layer.geometryIndicesByPaint[ordinal])
        try #require(layer.geometries.indices.contains(index))
        return layer.geometries[index]
    }

    /// 相同child以多个偏移引用，用来验证命令时钟独立而几何对象可以共享。
    static func file(_ elements: [SourceShape], offsets: [Int64] = [0, 5]) throws -> PAGFile {
        let child = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, start: 5,
            duration: 25, content: .shape(elements))])
        let root = try SceneFixtures.composition(2, layers: offsets.enumerated().map { index, offset in
            SceneFixtures.layer(UInt32(index + 10), content: .precomposition(id: 1, startFrame: offset))
        })
        return try SceneFixtures.build([child, root])
    }
}
