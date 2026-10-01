import Metal
import Testing
@testable import pag_swift

/// Trim输出进入真实Metal缓存的身份验证；不能用CPU几何相等代替三个buffer复用证据。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要Metal设备"))
struct MetalTrimPreparationTests {
    /// 颜色/渐变/组alpha复用，裁剪区间/描边宽度失效，返回旧帧恢复三个buffer且根pass直指drawable。
    @Test func trimFramesReuseOnlyMatchingGPUInputs() async throws {
        let owner = TrimGPUOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        var gradient = try MetalGradientFixtures.animatedColor()
        gradient.insert(.trimPaths(TrimBatchFixtures.source(0, 0.5)), at: 1)
        var stroke = try MetalGradientFixtures.dashedStroke(reversed: false)
        stroke.insert(.trimPaths(TrimBatchFixtures.source(0, 0.75)), at: 1)
        for (elements, changesGeometry, group) in [
            (try MetalTrimFixtures.filled(animatedColor: true), false, false),
            (try MetalTrimFixtures.filled(animatedRange: true), true, false),
            (try MetalTrimFixtures.groupOpacity(), false, true), (gradient, false, false), (stroke, true, false)
        ] {
            let scene = try await MetalStrokeFixtures.scene(elements)
            let first = try await ShapePathFixtures.plan(scene, at: 0)
            let next = try await ShapePathFixtures.plan(scene, at: 5)
            let returned = try await ShapePathFixtures.plan(scene, at: 0)
            try await owner.verify(first, next, returned, changesGeometry: changesGeometry, group: group)
        }
    }
}

/// 裸Metal对象只由此测试actor创建/访问，跨域只传递不可变PreparedFrame。
private actor TrimGPUOwner {
    /// 从入口转交的设备，不能把缓存buffer返回另一个隔离域。
    private let device: any MTLDevice

    /// 接收设备所有权，后续资源全部留在本actor。
    init(device: sending any MTLDevice) { self.device = device }

    /// 使用相同生产资源创建三份输入，检查身份和组附件生命周期，不把输入准备称为实际呈现。
    func verify(_ first: PreparedFrame, _ next: PreparedFrame, _ returned: PreparedFrame,
                changesGeometry: Bool, group: Bool) throws {
        let resources = try MetalResources(device: device)
        let a = try MetalFramePreparation.prepare(first, width: 100, height: 100, resources: resources)
        defer { a.releaseTransients() }
        let b = try MetalFramePreparation.prepare(next, width: 100, height: 100, resources: resources)
        defer { b.releaseTransients() }
        let c = try MetalFramePreparation.prepare(returned, width: 100, height: 100, resources: resources)
        defer { c.releaseTransients() }
        #expect(a.passes.last?.attachment == nil && b.passes.last?.attachment == nil && c.passes.last?.attachment == nil)
        #expect(b.passes.count == (group ? 2 : 1))
        let old = a.passes.flatMap(\.draws).filter { $0.texture == nil }
        let new = b.passes.flatMap(\.draws).filter { $0.texture == nil }
        let restored = c.passes.flatMap(\.draws).filter { $0.texture == nil }
        try #require(!old.isEmpty && old.count == new.count && old.count == restored.count)
        for index in old.indices {
            #expect((old[index].mesh === new[index].mesh) == !changesGeometry)
            #expect((old[index].mesh.buffer === new[index].mesh.buffer) == !changesGeometry)
            #expect((old[index].mesh.nodes === new[index].mesh.nodes) == !changesGeometry)
            #expect((old[index].mesh.triangles === new[index].mesh.triangles) == !changesGeometry)
            #expect(old[index].mesh.buffer === restored[index].mesh.buffer)
            #expect(old[index].mesh.nodes === restored[index].mesh.nodes)
            #expect(old[index].mesh.triangles === restored[index].mesh.triangles)
        }
        if group {
            #expect(b.passes[0].rect.width < 100 && b.passes[0].rect.height < 100)
            #expect(b.passes[1].draws.first?.texture === b.passes[0].attachment?.texture)
        }
        a.releaseTransients()
        b.releaseTransients()
        c.releaseTransients()
        #expect(resources.groups.activeBytes == 0)
    }
}
