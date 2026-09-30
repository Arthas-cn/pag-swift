import Metal
import Testing
@testable import pag_swift

/// 新形状轨道的实际GPU输入复用；不把CPU几何身份当作三个Metal buffer都命中的证明。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"))
struct MetalShapePropertyPreparationTests {
    /// Ellipse与PolyStar的颜色复用三个GPU buffer，几何/拓扑变化失效；整体alpha仍只用局部附件。
    @Test func generatorFramesReuseOnlyMatchingGPUInputs() async throws {
        let owner = ShapePropertyGPUOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        for (elements, changesGeometry, hasOpacityGroup) in [
            (try MetalShapeGeneratorFixtures.color(polyStar: false), false, false),
            (try MetalShapeGeneratorFixtures.color(polyStar: true), false, false),
            (try MetalShapeGeneratorFixtures.ellipseSize(), true, false),
            (try MetalShapeGeneratorFixtures.starRadii(), true, false),
            (try MetalShapeGeneratorFixtures.polygonPoints(), true, false),
            (try MetalShapeGeneratorFixtures.groupOpacity(), false, true)
        ] {
            let scene = try await MetalStrokeFixtures.scene(elements)
            let first = try await ShapePathFixtures.plan(scene, at: 0)
            let changed = try await ShapePathFixtures.plan(scene, at: 5)
            let returned = try await ShapePathFixtures.plan(scene, at: 0)
            try await owner.verify(first, changed, returned, changesGeometry: changesGeometry, hasOpacityGroup: hasOpacityGroup)
        }
    }

    /// 颜色和组alpha保持几何输入，位置与矩形变化替换输入；透明组的局部附件最终直接合成到drawable。
    @Test func sourceFramesReuseOnlyMatchingGPUInputs() async throws {
        let owner = ShapePropertyGPUOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        for (elements, changesGeometry, hasOpacityGroup) in [
            (try MetalShapePropertyFixtures.color(), false, false),
            (try MetalShapePropertyFixtures.groupOpacity(), false, true),
            (try MetalShapePropertyFixtures.movingGroup(), true, false),
            (try MetalShapePropertyFixtures.rectangle(), true, false)
        ] {
            let scene = try await MetalStrokeFixtures.scene(elements)
            let first = try await ShapePathFixtures.plan(scene, at: 0)
            let changed = try await ShapePathFixtures.plan(scene, at: 5)
            let returned = try await ShapePathFixtures.plan(scene, at: 0)
            try await owner.verify(first, changed, returned, changesGeometry: changesGeometry, hasOpacityGroup: hasOpacityGroup)
        }
    }
}

/// 裸Metal对象在单一测试actor中创建和比较，跨隔离只接收不可变FramePlan输入。
private actor ShapePropertyGPUOwner {
    /// 接收所有权后的设备，不返回原调用域。
    private let device: any MTLDevice

    /// 断开调用方别名，后续资源访问均在本actor执行。
    init(device: sending any MTLDevice) { self.device = device }

    /// 对比首帧、中帧、返回首帧的实际网格和三个GPU buffer；局部附件在GPU提交前的测试结束时释放。
    func verify(_ first: PreparedFrame, _ changed: PreparedFrame, _ returned: PreparedFrame,
                changesGeometry: Bool, hasOpacityGroup: Bool) throws {
        let resources = try MetalResources(device: device)
        let before = try MetalFramePreparation.prepare(first, width: 100, height: 100, resources: resources)
        defer { before.releaseTransients() }
        let after = try MetalFramePreparation.prepare(changed, width: 100, height: 100, resources: resources)
        defer { after.releaseTransients() }
        let restored = try MetalFramePreparation.prepare(returned, width: 100, height: 100, resources: resources)
        defer { restored.releaseTransients() }
        #expect(before.passes.last?.attachment == nil && after.passes.last?.attachment == nil && restored.passes.last?.attachment == nil)
        #expect(after.passes.count == (hasOpacityGroup ? 2 : 1))
        let a = before.passes.flatMap(\.draws).filter { $0.texture == nil }
        let b = after.passes.flatMap(\.draws).filter { $0.texture == nil }
        let c = restored.passes.flatMap(\.draws).filter { $0.texture == nil }
        try #require(a.count == b.count && a.count == c.count && a.isEmpty == false)
        for index in a.indices {
            let old = a[index].mesh, new = b[index].mesh, original = c[index].mesh
            #expect((old === new) == (changesGeometry == false))
            #expect((old.buffer === new.buffer) == (changesGeometry == false))
            #expect((old.nodes === new.nodes) == (changesGeometry == false))
            #expect((old.triangles === new.triangles) == (changesGeometry == false))
            #expect(old === original && old.buffer === original.buffer && old.nodes === original.nodes && old.triangles === original.triangles)
        }
        if hasOpacityGroup {
            let local = after.passes[0]
            #expect(local.rect.width < 100 && local.rect.height < 100)
            #expect(after.passes[1].draws.first?.texture === local.attachment?.texture)
        }
        after.releaseTransients()
        #expect(resources.groups.activeBytes == 0)
    }
}
