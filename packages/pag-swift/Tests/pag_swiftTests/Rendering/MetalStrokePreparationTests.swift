import Metal
import Testing
@testable import pag_swift

/// 描边在真实Metal批次中的单次覆盖、paint顺序与输入缓存；像素另由drawable测试验证。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct MetalStrokePreparationTests {
    /// 两条中心线汇成一次无局部附件的绘制，交叉只有一份网格覆盖和源alpha。
    @Test func crossingUsesOneDrawAndOneAlpha() async throws {
        let scene = try await MetalStrokeFixtures.scene(MetalStrokeFixtures.crossing())
        let frame = try await ShapePathFixtures.plan(scene, at: 0)
        try await MetalStrokePreparationOwner(device: #require(MTLCreateSystemDefaultDevice())).verifyCrossing(frame)
    }

    /// 多paint半透明子组保留绘制顺序，整体alpha只在局部结果进入drawable时应用。
    @Test func subgroupKeepsPaintOrderAndCompositeAlpha() async throws {
        let scene = try await MetalStrokeFixtures.scene(MetalStrokeFixtures.mixedGroup())
        let frame = try await ShapePathFixtures.plan(scene, at: 0)
        try await MetalStrokePreparationOwner(device: #require(MTLCreateSystemDefaultDevice())).verifyGroup(frame)
    }

    /// 静态和颜色动画保持三个GPU buffer身份；宽度变化必须生成新的输入。
    @Test func sourceFramesReuseOnlyUnchangedGeometry() async throws {
        let owner = MetalStrokePreparationOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        for (elements, changesGeometry, changesColor) in [
            (try MetalStrokeFixtures.crossing(), false, false),
            (try MetalStrokeFixtures.animatedColor(), false, true),
            (try MetalStrokeFixtures.animatedWidth(), true, false)
        ] {
            let scene = try await MetalStrokeFixtures.scene(elements)
            let first = try await ShapePathFixtures.plan(scene, at: 0)
            let last = try await ShapePathFixtures.plan(scene, at: 10)
            try await owner.verifyReuse(first, last, changesGeometry: changesGeometry, changesColor: changesColor)
        }
    }
}

/// 裸GPU对象只在此测试actor中比较，跨域只接收不可变PreparedFrame。
private actor MetalStrokePreparationOwner {
    /// 一次性转交的设备；没有返回原调用域的别名。
    private let device: any MTLDevice

    /// 接收设备后所有资源创建与访问在此隔离域完成。
    init(device: sending any MTLDevice) { self.device = device }

    /// 解析并集面积30×10×2−10×10=500，交叉内点应只有一次覆盖。
    func verifyCrossing(_ frame: PreparedFrame) throws {
        let batch = try prepare(frame, resources: MetalResources(device: device))
        defer { batch.releaseTransients() }
        try #require(batch.passes.count == 1 && batch.drawCount == 1)
        #expect(batch.loans.isEmpty && batch.passes[0].attachment == nil)
        let draw = batch.passes[0].draws[0]
        #expect(draw.texture == nil && draw.video == nil)
        #expect(draw.uniforms.color == SIMD4<Float>(128.0 / 255, 0, 0, 128.0 / 255))
        #expect(abs(GeometryTestSupport.area(draw.mesh.source) - 500) < 1e-8)
        #expect(GeometryTestSupport.coverage(draw.mesh.source, at: ScenePoint(x: 25.2, y: 25.3)) == 1)
    }

    /// 绿fill先于红Below和蓝Above，局部附件仅覆盖内容，最终pass直接指向drawable。
    func verifyGroup(_ frame: PreparedFrame) throws {
        let resources = try MetalResources(device: device)
        let batch = try prepare(frame, resources: resources)
        defer { batch.releaseTransients() }
        try #require(batch.passes.count == 2 && batch.loans.count == 1)
        let content = batch.passes[0], root = batch.passes[1]
        #expect(content.draws.map(\.uniforms.color) == [SIMD4<Float>(0, 1, 0, 1),
            SIMD4<Float>(1, 0, 0, 1), SIMD4<Float>(0, 0, 1, 1)])
        #expect(content.rect.width < 100 && content.rect.height < 100)
        #expect(content.attachment?.texture.storageMode == .private)
        try #require(root.draws.count == 1)
        #expect(root.attachment == nil && root.draws[0].texture === content.attachment?.texture)
        #expect(root.draws[0].uniforms.color == SIMD4<Float>(repeating: 128.0 / 255))
        batch.releaseTransients()
        #expect(resources.groups.activeBytes == 0)
    }

    /// 通过实际MetalMesh和三个buffer的对象身份，区分几何命中与只更新绘制常量。
    func verifyReuse(_ first: PreparedFrame, _ last: PreparedFrame,
                     changesGeometry: Bool, changesColor: Bool) throws {
        let resources = try MetalResources(device: device)
        let a = try prepare(first, resources: resources)
        defer { a.releaseTransients() }
        let b = try prepare(last, resources: resources)
        defer { b.releaseTransients() }
        let before = try #require(a.passes.last?.draws.first), after = try #require(b.passes.last?.draws.first)
        #expect((before.mesh === after.mesh) == !changesGeometry)
        #expect((before.mesh.buffer === after.mesh.buffer) == !changesGeometry)
        #expect((before.mesh.nodes === after.mesh.nodes) == !changesGeometry)
        #expect((before.mesh.triangles === after.mesh.triangles) == !changesGeometry)
        #expect((before.uniforms.color != after.uniforms.color) == changesColor)
        #expect(abs(GeometryTestSupport.area(after.mesh.source) - (changesGeometry ? 800 : 500)) < 1e-8)
    }

    /// 使用和生产owner相同的入口；成功批次由调用者归还局部附件。
    private func prepare(_ frame: PreparedFrame, resources: MetalResources) throws -> MetalFrameBatch {
        try MetalFramePreparation.prepare(frame, width: 100, height: 100, resources: resources)
    }
}
