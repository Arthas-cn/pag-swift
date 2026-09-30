import Testing
@testable import pag_swift

/// 描边准备接入真实公共帧计划的身份与时间边界；动态命令和可复用几何不混为一个缓存键。
struct StrokeShapePlanningTests {
    /// 两个同源实例在同一根帧取不同合成帧，颜色与alpha独立但几何和渲染网格可共享。
    @Test func instancesKeepIndependentPaintsWhileSharingGeometry() async throws {
        let source = StrokeFixtures.make(color: try StrokeFixtures.track(StrokeShapeFixtures.color(0), StrokeShapeFixtures.color(100)),
            opacity: try StrokeFixtures.track(UInt8(100), UInt8(200)))
        let elements: [SourceShape] = [StrokeShapeFixtures.rectangle(), .stroke(source)]
        let file = try StrokeShapeFixtures.file(elements)
        let scene = try await PreparedScene.prepare(file.composition)
        #expect(scene.shapes.isEmpty && scene.dynamicShapes != nil)
        let frame = try await ShapePathFixtures.plan(scene, at: 10)
        let commands = ShapePathFixtures.fills(frame)
        try #require(commands.count == 2 && frame.shapes.count == 2)
        #expect(Set(commands.compactMap(\.geometryID.sampleFrame)) == [5, 10])
        #expect(commands[0].geometryID != commands[1].geometryID)
        let first = try #require(frame.shapes[commands[0].geometryID])
        let second = try #require(frame.shapes[commands[1].geometryID])
        #expect(first === second && first.stroke?.style.width == 2)
        for command in commands {
            let sample = try #require(command.geometryID.sampleFrame)
            #expect(try command.material.solidColor().red == (sample == 5 ? 50 : 100))
            #expect(command.opacity == (sample == 5 ? 150.0 : 200.0) / 255)
        }
        var cache = try RenderGeometryCache()
        var cold = try GeometryBudget()
        let mesh = try cache.mesh(for: .shape(first), transform: .identity, budget: &cold)
        var warm = try GeometryBudget(maximumWork: 1)
        #expect(try cache.mesh(for: .shape(second), transform: .identity, budget: &warm) === mesh)
        #expect(abs(GeometryTestSupport.area(mesh) - 160) < 1e-8)
    }

    /// 常量stroke在安装时只准备一次，两个时刻及同一文档再准备共享静态几何，不创建动态owner。
    @Test func staticStrokesReuseInstalledGeometry() async throws {
        let file = try StrokeShapeFixtures.file([StrokeShapeFixtures.rectangle(), .stroke(StrokeFixtures.make())], offsets: [0])
        let scene = try await PreparedScene.prepare(file.composition)
        #expect(scene.dynamicShapes == nil && scene.shapes.count == 1)
        let first = try await ShapePathFixtures.plan(scene, at: 10)
        let second = try await ShapePathFixtures.plan(scene, at: 15)
        let id = try #require(ShapePathFixtures.fills(first).first?.geometryID)
        #expect(id.sampleFrame == nil && first.shapes[id] === second.shapes[id])
        let reused = try await PreparedScene.prepare(file.composition, reusing: scene)
        let reference = try #require(scene.shapes.keys.first)
        #expect(reused.shapes[reference] === scene.shapes[reference])
    }
}
