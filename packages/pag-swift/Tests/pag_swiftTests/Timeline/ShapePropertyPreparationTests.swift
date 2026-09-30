import Testing
@testable import pag_swift

/// 新增形状轨道的逐帧几何、paint身份和透明组路径语义，不通过尚未开放的正式字节入口。
struct ShapePropertyPreparationTests {
    /// 颜色与正alpha变化只更新paint，完整几何对象和已准备网格均可复用。
    @Test func fillColorAndOpacityReuseGeometry() throws {
        let color = try ShapePropertyFixtures.track(SceneColor(red: 0, green: 200, blue: 10),
                                                    SceneColor(red: 100, green: 0, blue: 30))
        let elements = [ShapePropertyFixtures.rectangle(), ShapePropertyFixtures.fill(color: color,
            opacity: try ShapePropertyFixtures.track(UInt8(100), UInt8(200)))]
        let first = try ShapePropertyFixtures.prepare(elements)
        let middle = try ShapePropertyFixtures.prepare(elements, frame: 5, reuse: [first])
        let paint = try #require(ShapePropertyFixtures.paints(middle).first)
        #expect(try paint.material.solidColor() == SceneColor(red: 50, green: 100, blue: 20) && paint.opacity == 150.0 / 255)
        #expect(first.geometries[0] === middle.geometries[0])
        var cache = try RenderGeometryCache()
        var cold = try GeometryBudget()
        let mesh = try cache.mesh(for: .shape(first.geometries[0]), transform: .identity, budget: &cold)
        var warm = try GeometryBudget(maximumWork: 1)
        #expect(try cache.mesh(for: .shape(middle.geometries[0]), transform: .identity, budget: &warm) === mesh)
        #expect(warm.work == 1 && cold.work > 1)
    }

    /// 先前fill透明穿零不改变之后paint的源ordinal；恢复可借用更早候选，Below顺序保持。
    @Test func zeroAlphaPreservesLaterPaintIdentityAndPaths() throws {
        let blue = SceneColor(red: 0, green: 0, blue: 255)
        let elements = [ShapePropertyFixtures.rectangle(), ShapePropertyFixtures.fill(
            opacity: try ShapePropertyFixtures.track(UInt8(255), UInt8(0))),
            ShapePropertyFixtures.fill(color: .init(constant: blue))]
        let first = try ShapePropertyFixtures.prepare(elements)
        let hidden = try ShapePropertyFixtures.prepare(elements, frame: 10, reuse: [first])
        #expect(first.geometryIndicesByPaint == [0: 0, 1: 0])
        #expect(hidden.geometryIndicesByPaint == [1: 0])
        #expect(hidden.geometries[0] === first.geometries[0])
        #expect(try ShapePropertyFixtures.paints(first).map { try $0.material.solidColor() } == [blue, .defaultFill])
        #expect(try ShapePropertyFixtures.paints(hidden).map { try $0.material.solidColor() } == [blue])
        let restored = try ShapePropertyFixtures.prepare(elements, reuse: [hidden, first])
        #expect(restored.geometryIndicesByPaint == first.geometryIndicesByPaint)
        #expect(restored.geometries[0] === first.geometries[0])
    }

    /// 组alpha只包裹组内paint；零alpha仍向父fill提供路径，父几何身份和颜色保持。
    @Test func groupOpacityKeepsParentPathsAcrossZero() throws {
        let transform = ShapePropertyFixtures.group(opacity: try ShapePropertyFixtures.track(UInt8(255), UInt8(0)))
        let blue = SceneColor(red: 0, green: 0, blue: 255)
        let elements: [SourceShape] = [.group(transform, [ShapePropertyFixtures.rectangle(), ShapePropertyFixtures.fill()]),
            ShapePropertyFixtures.fill(color: .init(constant: blue))]
        let first = try ShapePropertyFixtures.prepare(elements)
        let middle = try ShapePropertyFixtures.prepare(elements, frame: 5, reuse: [first])
        let hidden = try ShapePropertyFixtures.prepare(elements, frame: 10, reuse: [middle, first])
        #expect(try ShapePropertyFixtures.geometry(middle, ordinal: 0) === ShapePropertyFixtures.geometry(first, ordinal: 0))
        #expect(try ShapePropertyFixtures.geometry(hidden, ordinal: 1) === ShapePropertyFixtures.geometry(first, ordinal: 1))
        #expect(hidden.geometryIndicesByPaint == [1: 0] && hidden.instructions.count == 1)
        #expect(ShapePropertyFixtures.paints(middle).map(\.opacity) == [1, 1])
        guard case .beginOpacityGroup(let alpha) = middle.instructions[1],
              case .endOpacityGroup = middle.instructions[3] else {
            Issue.record("组alpha必须是整体边界，不能分别乘入各paint")
            return
        }
        #expect(alpha == 127.0 / 255)
        let restored = try ShapePropertyFixtures.prepare(elements, reuse: [hidden, middle, first])
        #expect(try ShapePropertyFixtures.geometry(restored, ordinal: 0) === ShapePropertyFixtures.geometry(first, ordinal: 0))
    }

    /// 组的六种矩阵字段各自变化均使完整几何失配，回到原状态才复用旧几何。
    @Test(arguments: 0..<6)
    func eachGroupMatrixChangeInvalidatesGeometry(_ field: Int) throws {
        let point = try ShapePropertyFixtures.track(ScenePoint.zero, ScenePoint(x: 3, y: 5))
        let scalar = try ShapePropertyFixtures.track(0.0, 30)
        let transform = try ShapePropertyFixtures.group(anchor: field == 0 ? point : .init(constant: .zero),
            position: field == 1 ? point : .init(constant: .zero),
            scale: field == 2 ? ShapePropertyFixtures.track(.one, ScenePoint(x: -2, y: 0)) : .init(constant: .one),
            skew: field == 3 ? scalar : .init(constant: 45), skewAxis: field == 4 ? scalar : .init(constant: 0),
            rotation: field == 5 ? scalar : .init(constant: 0))
        let elements: [SourceShape] = [.group(transform, [ShapePropertyFixtures.rectangle(), ShapePropertyFixtures.fill()])]
        let first = try ShapePropertyFixtures.prepare(elements)
        let changed = try ShapePropertyFixtures.prepare(elements, frame: 10, reuse: [first])
        #expect(first.geometries[0] !== changed.geometries[0])
        #expect(first.geometries[0].contours[0].matrix != changed.geometries[0].contours[0].matrix)
        let restored = try ShapePropertyFixtures.prepare(elements, reuse: [changed, first])
        #expect(restored.geometries[0] === first.geometries[0])
    }

    /// 尺寸、中心和圆角单独变化都拒绝旧几何；负尺寸仍遵守既有先限制圆角后规范化规则。
    @Test(arguments: 0..<3)
    func rectangleTracksUpdateGeometry(_ field: Int) throws {
        let rectangle = try ShapePropertyFixtures.rectangle(
            size: field == 0 ? ShapePropertyFixtures.track(ScenePoint(x: 20, y: 20), ScenePoint(x: -40, y: 20))
                            : .init(constant: ScenePoint(x: 20, y: 20)),
            position: field == 1 ? ShapePropertyFixtures.track(.zero, ScenePoint(x: 30, y: 40)) : .init(constant: .zero),
            roundness: field == 2 ? ShapePropertyFixtures.track(2.0, 6) : .init(constant: 2))
        let elements = [rectangle, ShapePropertyFixtures.fill()]
        let first = try ShapePropertyFixtures.prepare(elements)
        let changed = try ShapePropertyFixtures.prepare(elements, frame: 10, reuse: [first])
        #expect(first.geometries[0] !== changed.geometries[0])
        guard case .rectangle(let contour) = changed.geometries[0].contours[0] else {
            Issue.record("矩形动画必须复用圆角矩形核心")
            return
        }
        #expect(contour.size == ScenePoint(x: field == 0 ? 40 : 20, y: 20))
        #expect(contour.center == (field == 1 ? ScenePoint(x: 30, y: 40) : .zero))
        #expect(contour.radius == (field == 0 ? 0 : field == 2 ? 6 : 2))
        let restored = try ShapePropertyFixtures.prepare(elements, reuse: [changed, first])
        #expect(restored.geometries[0] === first.geometries[0])
    }

    /// 找到动画后仍扫描后续深度和预算；预取消的空列表也不能返回静态成功。
    @Test func classificationKeepsDepthBudgetAndCancellationChecks() async throws {
        let animated = ShapePropertyFixtures.fill(opacity: try ShapePropertyFixtures.track(UInt8(0), UInt8(0)))
        var nested = animated
        for _ in 0..<65 { nested = .group(ShapePropertyFixtures.group(), [nested]) }
        var budget = FramePlanBudget(limit: 1_000_000)
        #expect(throws: PAGError.resourceLimitExceeded("maximumShapeDepth")) {
            try ShapePreparation.isAnimated([animated, nested], budget: &budget)
        }
        var limited = FramePlanBudget(limit: 31)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try ShapePreparation.isAnimated([animated, ShapePropertyFixtures.rectangle()], budget: &limited)
        }
        await #expect(throws: CancellationError.self) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.cancelAll()
                group.addTask {
                    var budget = FramePlanBudget(limit: 1_000_000)
                    _ = try ShapePreparation.isAnimated([], budget: &budget)
                }
                for try await _ in group {}
            }
        }
    }
}
