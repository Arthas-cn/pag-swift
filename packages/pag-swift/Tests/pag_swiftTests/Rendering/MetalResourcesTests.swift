import Metal
import Testing
@testable import pag_swift

/// 真设备输入上传与MSL编译，沙箱没有GPU时明确跳过；不读取任何最终帧像素。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct MetalResourcesTests {
    /// 真实管线可编译，输入buffer/texture按身份复用，缓存淘汰不破坏调用方持有的资源。
    @Test func compilesPipelinesAndReusesImmutableInputs() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let owner = MetalResourceTestOwner(device: device)
        let image = try await PAGImage.load(data: PAGFixtures.data(named: "media/rgba-corners.png"))
        try await owner.verifyResources(image)
    }

    /// TEXT04真实字形生成两轮GPU输入，整组alpha保留为一次局部合成。
    @Test func preparesRealTextAndCompositeOpacity() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let owner = MetalResourceTestOwner(device: device)
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: file.composition.size, scale: 1, mode: .none)
        try await owner.verifyFrame(frame, size: file.composition.size)
    }
}

/// 测试独占的GPU资源域，只把Sendable来源送入，不让测试主任务拿到裸Metal对象。
private actor MetalResourceTestOwner {
    /// 一次性sending转交的设备，之后所有资源操作留在本actor。
    private let device: any MTLDevice

    /// 接收断开调用域别名的真实设备。
    init(device: sending any MTLDevice) { self.device = device }

    /// 验证输入布局、资源身份、预算和LRU释放；buffer.contents只检查CPU刚写入的输入顶点。
    func verifyResources(_ image: PAGImage) throws {
        let resources = try MetalResources(device: device)
        let firstPipelines = try resources.pipelines(), secondPipelines = try resources.pipelines()
        #expect(firstPipelines.solid === secondPipelines.solid && firstPipelines.image === secondPipelines.image)
        var budget = try MetalFrameBudget()
        let first = try resources.rectangle(budget: &budget)
        let second = try resources.rectangle(budget: &budget)
        #expect(first.nodes === second.nodes && first.triangles === second.triangles && first.nodeCount == 1)
        #expect(first.byteCost >= first.source.estimatedBytes + first.buffer.allocatedSize + first.nodes.allocatedSize + first.triangles.allocatedSize)
        #expect(first === second && first.buffer.storageMode != .private && first.buffer.storageMode != .memoryless)
        let input = first.buffer.contents().bindMemory(to: MetalVertex.self, capacity: 6)
        #expect(input[0].position == .zero && input[2].position == .one)
        #expect(input[2].textureCoordinate == .one && first.buffer.length == 96)
        let texture = try resources.image(image, budget: &budget)
        let repeatTexture = try resources.image(image, budget: &budget)
        #expect(texture === repeatTexture && texture.pixelFormat == .rgba8Unorm)
        #expect(texture.width == 2 && texture.height == 2 && texture.usage == .shaderRead)
        #expect(resources.count == 2 && resources.byteCount > 0)
        var tiny = try MetalFrameBudget(maximumBytes: 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumMetalFrameBytes")) {
            try resources.rectangle(budget: &tiny)
        }
        resources.removeAll()
        #expect(resources.count == 0 && resources.byteCount == 0 && first.buffer.length == 96)
        let uncached = try MetalResources(device: device, byteLimit: 0)
        var nextFrame = try MetalFrameBudget()
        let a = try uncached.rectangle(budget: &budget), sameFrame = try uncached.rectangle(budget: &budget)
        let b = try uncached.rectangle(budget: &nextFrame)
        #expect(a === sameFrame && a !== b && uncached.count == 0)
    }

    /// 验证计划完整性门禁，仍未实际提交drawable，不能用本用例声称文字已正确显示。
    func verifyFrame(_ frame: PreparedFrame, size: PAGSize) throws {
        let resources = try MetalResources(device: device)
        let batch = try MetalFramePreparation.prepare(frame, width: Int(size.width), height: Int(size.height), resources: resources)
        defer { batch.releaseTransients() }
        let draws = try #require(batch.passes.last).draws
        #expect(batch.passes.count == 1 && draws.count == 18 && draws.allSatisfy { $0.texture == nil })
        #expect(draws.allSatisfy { $0.uniforms.counts.x == 4 && $0.uniforms.counts.y > 0 })
        let layer = try #require(frame.plan.commands.compactMap { command -> PAGLayerID? in
            if case .text(let text) = command { text.layerID } else { nil }
        }.first)
        let commands = [FrameCommand.beginOpacityGroup(FrameOpacityGroup(layerID: layer, opacity: 0.5))]
            + frame.plan.commands + [.endOpacityGroup]
        let grouped = PreparedFrame(plan: FramePlan(time: frame.plan.time, targetBounds: frame.plan.targetBounds, commands: commands),
                                        images: frame.images, shapes: frame.shapes, texts: frame.texts)
        let composite = try MetalFramePreparation.prepare(grouped, width: Int(size.width), height: Int(size.height), resources: resources)
        defer { composite.releaseTransients() }
        #expect(composite.passes.count == 2 && composite.loans.count == 1)
        #expect(composite.passes[0].draws.count == 18 && composite.passes[1].draws.count == 1)
        #expect(composite.passes[1].draws[0].uniforms.color == SIMD4<Float>(repeating: 0.5))
    }
}
