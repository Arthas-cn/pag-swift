import Metal
import Testing
@testable import pag_swift

/// 覆盖计算接入实际批次的资源、裁剪与边缘范围；不读取GPU输出画面。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct MetalCoveragePreparationTests {
    /// 同一裁剪作用于多个图元时共享一段凸边界，分数像素外沿仍产生候选片元。
    @Test func sharesClipEdgesAndIncludesFractionalBoundaryPixels() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        try await MetalCoveragePreparationOwner(device: device).verifySharedClips()
    }

    /// 两个旋转裁剪的AABB虽重叠，真实交集为空时不留下无裁剪绘制。
    @Test func emptyConvexIntersectionSkipsDraws() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        try await MetalCoveragePreparationOwner(device: device).verifyEmptyIntersection()
    }

    /// 跨帧命中同一网格应复用三个buffer，并继续执行完整成本门禁。
    @Test func cachedCoverageResourcesRemainFullyBudgeted() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        try await MetalCoveragePreparationOwner(device: device).verifyCachedCost()
    }

    /// 裁剪输入按实际Metal分配加元数据计费，无裁剪也只绑定合法占位输入。
    @Test func clipBufferUsesActualAllocationCost() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        try await MetalCoveragePreparationOwner(device: device).verifyClipCost()
    }
}

/// 测试GPU输入只在此actor访问，测试调用域仅持有Sendable结果。
private actor MetalCoveragePreparationOwner {
    /// 一次性转入的设备，不返回调用域。
    private let device: any MTLDevice

    /// 接收断开原域别名的设备。
    init(device: sending any MTLDevice) { self.device = device }

    /// 校验两个绘制引用同一凸裁剪范围；输入检查没有帧像素读回。
    func verifySharedClips() throws {
        let resources = try MetalResources(device: device)
        let clip = FrameClip(size: try PAGSize(width: 80, height: 80), matrix: try .translation(x: 0.25, y: 0.5))
        let begin = FrameCommand.beginGroup(FrameGroup(layerID: nil, frame: 0, clip: clip, opacity: 1))
        let batch = try prepare([begin, MetalGroupFixtures.solid(x: 10.25, y: 20.75),
                                 begin, MetalGroupFixtures.solid(x: 40.25, y: 20.75), .endGroup, .endGroup], resources)
        defer { batch.releaseTransients() }
        let draws = try #require(batch.passes.last).draws
        try #require(draws.count == 2)
        #expect(batch.loans.isEmpty && batch.clipBuffer.length == 4 * MemoryLayout<SIMD4<Float>>.stride)
        #expect(draws.allSatisfy { $0.uniforms.counts.x == 4 && $0.uniforms.counts.w == 0 })
        let edges = batch.clipBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 4)
        #expect(Set((0..<4).map { SIMD2(edges[$0].x, edges[$0].y) })
                == Set([SIMD2<Float>(0.25, 0.5), SIMD2(80.25, 0.5), SIMD2(80.25, 80.5), SIMD2(0.25, 80.5)]))
        let first = draws[0].uniforms
        // 包围矩形向外扩一像素；真实边缘由片元覆盖求交，不能把此矩形当作实心内容。
        #expect(abs(first.rasterBounds.x - (-0.82)) < 1e-6)
        #expect(abs(first.rasterBounds.y - 0.62) < 1e-6)
        #expect(abs(first.rasterBounds.z - (-0.36)) < 1e-6)
        #expect(abs(first.rasterBounds.w - 0.16) < 1e-6)
        #expect(first.horizontalPixels == SIMD4<Float>(20, 0, 10.25, 0))
        #expect(first.verticalPixels == SIMD4<Float>(0, 20, 20.75, 0))
    }

    /// 两条平行窄矩形彼此分离，不能因AABB相交而启用零边数的无限裁剪语义。
    func verifyEmptyIntersection() throws {
        let resources = try MetalResources(device: device)
        let size = try PAGSize(width: 40, height: 2)
        let first = FrameClip(size: size, matrix: try SceneAffine.rotation(degrees: 45).following(.translation(x: 20, y: 20)))
        let second = FrameClip(size: size, matrix: try SceneAffine.rotation(degrees: 45).following(.translation(x: 15, y: 25)))
        var clips = MetalClipValues()
        try clips.append(first)
        try clips.append(second)
        #expect(!clips.isEmpty && clips.bounds != nil)
        let commands: [FrameCommand] = [
            .beginGroup(FrameGroup(layerID: nil, frame: 0, clip: first, opacity: 1)),
            .beginGroup(FrameGroup(layerID: nil, frame: 0, clip: second, opacity: 1)),
            try MetalGroupFixtures.solid(x: 20, y: 20), .endGroup, .endGroup
        ]
        let batch = try prepare(commands, resources)
        defer { batch.releaseTransients() }
        #expect(batch.drawCount == 0 && batch.passes.count == 1 && batch.loans.isEmpty)
        #expect(batch.clipBuffer.length == MemoryLayout<SIMD4<Float>>.stride)
    }

    /// 命中后的成本包含源对象、顶点和BVH，预算不足不得借缓存绕过限制。
    func verifyCachedCost() throws {
        let resources = try MetalResources(device: device)
        var firstFrame = try MetalFrameBudget()
        let first = try resources.rectangle(budget: &firstFrame)
        var nextFrame = try MetalFrameBudget(maximumBytes: first.byteCost + 128)
        let next = try resources.rectangle(budget: &nextFrame)
        #expect(first === next && first.nodes === next.nodes && first.triangles === next.triangles)
        #expect(throws: PAGError.resourceLimitExceeded("maximumMetalFrameBytes")) { try nextFrame.reserve(1) }
        var tooSmall = try MetalFrameBudget(maximumBytes: first.byteCost + 127)
        #expect(throws: PAGError.resourceLimitExceeded("maximumMetalFrameBytes")) { try resources.rectangle(budget: &tooSmall) }
        resources.removeAll()
        var freshFrame = try MetalFrameBudget()
        let fresh = try resources.rectangle(budget: &freshFrame)
        #expect(fresh !== first && fresh.nodes !== first.nodes && fresh.triangles !== first.triangles)
        #expect(first.nodeCount > 0 && first.buffer.length > 0)
    }

    /// 以实际设备分配为独立参照，恰好足够与少一字节必须分别成功和失败。
    func verifyClipCost() throws {
        let resources = try MetalResources(device: device)
        let values = [SIMD4<Float>(0, 0, 10, 0), SIMD4(10, 0, 10, 10)]
        var initial = try MetalFrameBudget()
        let probe = try resources.clipBuffer(values, budget: &initial)
        let cost = max(probe.length, probe.allocatedSize) + 512
        var exact = try MetalFrameBudget(maximumBytes: cost)
        let result = try resources.clipBuffer(values, budget: &exact)
        #expect(result.length == values.count * MemoryLayout<SIMD4<Float>>.stride)
        #expect(throws: PAGError.resourceLimitExceeded("maximumMetalFrameBytes")) { try exact.reserve(1) }
        var insufficient = try MetalFrameBudget(maximumBytes: cost - 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumMetalFrameBytes")) {
            try resources.clipBuffer(values, budget: &insufficient)
        }
    }

    /// 构造100像素显示批次；每个调用方负责归还成功借出的局部附件。
    private func prepare(_ commands: [FrameCommand], _ resources: MetalResources) throws -> MetalFrameBatch {
        try MetalFramePreparation.prepare(MetalGroupFixtures.frame(commands), width: 100, height: 100, resources: resources)
    }
}
