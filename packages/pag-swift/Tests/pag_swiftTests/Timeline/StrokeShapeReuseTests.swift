import Testing
@testable import pag_swift

/// 同源paint的几何身份复用；颜色/alpha可共享，路径、样式和任意矩阵变化必须拒绝。
struct StrokeShapeReuseTests {
    /// 只有颜色和正alpha变化时几何保持同一对象，两个源帧可命中同一真实渲染网格。
    @Test func colorAndOpacityReuseGeometryAndMesh() throws {
        let path = try ShapePathFixtures.square(20)
        let source = StrokeFixtures.make(color: try StrokeFixtures.track(StrokeShapeFixtures.color(0), StrokeShapeFixtures.color(100)),
            opacity: try StrokeFixtures.track(UInt8(100), UInt8(200)))
        let elements: [SourceShape] = [.path(.init(constant: path)), .stroke(source)]
        let first = try StrokeShapeFixtures.prepare(elements)
        let second = try StrokeShapeFixtures.prepare(elements, frame: 5, reuse: [first])
        let a = try StrokeShapeFixtures.geometry(first, ordinal: 0)
        let b = try StrokeShapeFixtures.geometry(second, ordinal: 0)
        #expect(a === b)
        #expect(try StrokeShapeFixtures.paints(first)[0].material.solidColor().red == 0)
        #expect(try StrokeShapeFixtures.paints(second)[0].material.solidColor().red == 50)
        #expect(StrokeShapeFixtures.paints(second)[0].opacity == 150.0 / 255)
        var cache = try RenderGeometryCache()
        var cold = try GeometryBudget()
        let mesh = try cache.mesh(for: .shape(a), transform: .identity, budget: &cold)
        var warm = try GeometryBudget(maximumWork: 1)
        #expect(try cache.mesh(for: .shape(b), transform: .identity, budget: &warm) === mesh)
        #expect(warm.work == 1 && cold.work > 1)
    }

    /// 前paint的alpha或width过零会改变紧凑下标；源ordinal保持后paint身份，恢复时可借更早候选。
    @Test(arguments: [true, false])
    func hiddenEarlierPaintDoesNotShiftReuseIdentity(_ usesOpacity: Bool) throws {
        let firstStroke = StrokeFixtures.make(
            width: usesOpacity ? .init(constant: 2) : try StrokeFixtures.track(2.0, 0),
            opacity: usesOpacity ? try StrokeFixtures.track(UInt8(255), UInt8(0)) : .init(constant: 255))
        let elements: [SourceShape] = [StrokeShapeFixtures.rectangle(), .stroke(firstStroke),
            .stroke(StrokeFixtures.make(width: .init(constant: 4)))]
        let before = try StrokeShapeFixtures.prepare(elements)
        let hidden = try StrokeShapeFixtures.prepare(elements, frame: 10, reuse: [before])
        #expect(before.geometryIndicesByPaint == [0: 0, 1: 1])
        #expect(hidden.geometryIndicesByPaint == [1: 0])
        #expect(hidden.geometries[0] === before.geometries[1])
        #expect(hidden.geometries[0] !== before.geometries[0])
        let restored = try StrokeShapeFixtures.prepare(elements, reuse: [hidden, before])
        #expect(restored.geometryIndicesByPaint == [0: 0, 1: 1])
        #expect(restored.geometries[0] === before.geometries[0] && restored.geometries[1] === before.geometries[1])
    }

    /// 连续fill被stroke隔开仍共享原fill快照；不同种类paint不能以相同中心线混用几何。
    @Test func strokeDoesNotInvalidateConsecutiveFillSnapshot() throws {
        let elements: [SourceShape] = [StrokeShapeFixtures.rectangle(), .fill(color: .defaultFill, opacity: 255),
            .stroke(StrokeFixtures.make()), .fill(color: StrokeShapeFixtures.color(100), opacity: 255)]
        let first = try StrokeShapeFixtures.prepare(elements)
        let second = try StrokeShapeFixtures.prepare(elements, frame: 5, reuse: [first])
        #expect(first.geometryIndicesByPaint == [0: 0, 1: 1, 2: 0])
        #expect(first.geometries.count == 2 && first.geometries[0].stroke == nil && first.geometries[1].stroke != nil)
        #expect(second.geometries[0] === first.geometries[0] && second.geometries[1] === first.geometries[1])
    }

    /// 宽度、miter、dash长度和相位单独改变都拒绝共享；最近候选不匹配时允许命中更早原状态。
    @Test func animatedGeometryStylesRejectReuseUntilStateReturns() throws {
        let track = try StrokeFixtures.track(2.0, 4)
        let variants = [StrokeFixtures.make(width: track), StrokeFixtures.make(miter: track),
            StrokeFixtures.make(dashes: try SourceDashes(offset: track, intervals: [.init(constant: 10)])),
            StrokeFixtures.make(dashes: try SourceDashes(offset: .init(constant: 0), intervals: [track]))]
        for source in variants {
            let elements: [SourceShape] = [StrokeShapeFixtures.rectangle(), .stroke(source)]
            let first = try StrokeShapeFixtures.prepare(elements)
            let changed = try StrokeShapeFixtures.prepare(elements, frame: 10, reuse: [first])
            #expect(first.geometries[0] !== changed.geometries[0])
            let returned = try StrokeShapeFixtures.prepare(elements, reuse: [changed, first])
            #expect(returned.geometries[0] === first.geometries[0])
        }
    }

    /// 路径对象是身份边界：数值相同的形变仍是新路径，不能靠深比较或hash把它合并。
    @Test func equalInterpolatedPathsRemainDifferentObjects() throws {
        let path = try ShapePathFixtures.square(20)
        let track = try StrokeFixtures.track(path, path)
        let elements: [SourceShape] = [.path(track), .stroke(StrokeFixtures.make())]
        let first = try StrokeShapeFixtures.prepare(elements, frame: 2)
        let second = try StrokeShapeFixtures.prepare(elements, frame: 3, reuse: [first])
        let a = try #require(first.geometries.first), b = try #require(second.geometries.first)
        #expect(a !== b)
        guard case .path(let p, _) = a.contours[0], case .path(let q, _) = b.contours[0] else {
            Issue.record("形变必须保留SourcePath而非提前转矩形")
            return
        }
        #expect(p !== q && p.points == q.points)
    }

    /// 轮廓顺序、路径身份、矩形全值和paint/contour矩阵都是精确匹配条件，不能忽略反向或半径。
    @Test func completeContourAndStrokeValuesAreRequired() throws {
        let path = try ShapePathFixtures.square(20), other = try ShapePathFixtures.square(10)
        let duplicate = try ShapePathFixtures.square(20)
        let style = StrokeGeometryTestSupport.style()
        let stroke = try ShapeStroke(style: style, matrix: .identity)
        let contours: [ShapeContour] = [.path(path, matrix: .identity), .path(other, matrix: .identity)]
        let geometry = try ShapeGeometry(contours: contours, stroke: stroke)
        var budget = FramePlanBudget(limit: 1_000_000)
        #expect(try geometry.matches(contours: contours, stroke: stroke, budget: &budget))
        #expect(budget.used == 64)
        for changed: [ShapeContour] in [contours.reversed(),
            [.path(duplicate, matrix: .identity), contours[1]],
            [.path(path, matrix: try .translation(x: 1, y: 0)), contours[1]]] {
            #expect(try !geometry.matches(contours: changed, stroke: stroke, budget: &budget))
        }
        for changed in [try ShapeStroke(style: style, matrix: .scale(x: 2, y: 1)),
            try ShapeStroke(style: StrokeGeometryTestSupport.style(cap: .round), matrix: .identity),
            try ShapeStroke(style: StrokeGeometryTestSupport.style(join: .round), matrix: .identity)] {
            #expect(try !geometry.matches(contours: contours, stroke: changed, budget: &budget))
        }
        #expect(try !geometry.matches(contours: contours, stroke: nil, budget: &budget))
        let original = try RoundedRectangleContour.make(size: ScenePoint(x: 20, y: 20), position: .zero,
            roundness: 2, reversed: false, matrix: .identity)
        let rectangle = try ShapeGeometry(contours: [.rectangle(original)], stroke: stroke)
        for changed in [try RoundedRectangleContour.make(size: ScenePoint(x: 22, y: 20), position: .zero,
                            roundness: 2, reversed: false, matrix: .identity),
                        try RoundedRectangleContour.make(size: ScenePoint(x: 20, y: 20), position: .zero,
                            roundness: 3, reversed: false, matrix: .identity),
                        try RoundedRectangleContour.make(size: ScenePoint(x: 20, y: 20), position: .zero,
                            roundness: 2, reversed: true, matrix: .identity),
                        try RoundedRectangleContour.make(size: ScenePoint(x: 20, y: 20), position: .zero,
                            roundness: 2, reversed: false, matrix: .translation(x: 1, y: 0))] {
            #expect(try !rectangle.matches(contours: [.rectangle(changed)], stroke: stroke, budget: &budget))
        }
    }

    /// 比较本身有预算和取消检查；命中已有几何不允许绕开新调用的低资源上限。
    @Test func reuseComparisonAndRetentionRemainBudgeted() async throws {
        let elements: [SourceShape] = [StrokeShapeFixtures.rectangle(), .stroke(StrokeFixtures.make())]
        let old = try StrokeShapeFixtures.prepare(elements)
        let geometry = try #require(old.geometries.first)
        var limited = FramePlanBudget(limit: 31)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try geometry.matches(contours: geometry.contours, stroke: geometry.stroke, budget: &limited)
        }
        var retained = FramePlanBudget(limit: old.estimatedBytes - 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try ShapePreparation.prepare(elements, reusing: [old], budget: &retained)
        }
        #expect(retained.used > 512)
        let task = Task {
            var budget = FramePlanBudget(limit: 1_000_000)
            withUnsafeCurrentTask { $0?.cancel() }
            return try geometry.matches(contours: geometry.contours, stroke: geometry.stroke, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
