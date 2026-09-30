import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import Metal
import Testing
import VideoToolbox
@testable import pag_swift

/// 真正系统帧到Metal输入缓存的保活和计费；此组不把纹理映射成功当成最终视频画面通过。
@Suite(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) && MTLCreateSystemDefaultDevice() != nil,
                 "需要H.264硬件与Metal"), .timeLimit(.minutes(1)))
struct MetalVideoResourcesTests {
    /// 左右/上下/奇数可见区域和不透明视频共用相同两平面导入，缓存命中与清理不破坏活动输入。
    @Test(arguments: ["RootLayerVideo.pag", "alpha.pag", "particle_video.pag", "MultiVideoSequence.pag"])
    func importsAndRetainsActualVideoPlanes(_ name: String) async throws {
        let source = try #require(await PAGVideoFixtures.compositions(in: name).first?.video.sequences.last)
        let store = VideoFrameStore()
        let frame = try await store.frame(for: source, at: 0)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let owner = MetalVideoTestOwner(device: device)
        try await owner.verify(frame)
    }

    /// 禁用跨帧缓存仍需在单帧保活CV包装和缓冲；单帧预算耗尽不能先消费输入槽。
    @Test func uncachedInputsRemainAliveForFrameBudget() async throws {
        let source = try #require(await PAGVideoFixtures.compositions(in: "RootLayerVideo.pag").first?.video.sequences.last)
        let frame = try await VideoFrameStore().frame(for: source, at: 1)
        let device = try #require(MTLCreateSystemDefaultDevice())
        try await MetalVideoTestOwner(device: device).verifyUncached(frame)
    }
}

/// 测试独占的后台GPU域；原始CV/Metal对象从不作为actor结果交回调用者。
private actor MetalVideoTestOwner {
    /// 所有导入、缓存和释放均发生在同一后台执行器。
    nonisolated private let executor = DispatchSerialQueue(label: "pag.video.metal.test")
    /// 明确actor的实际执行位置，非主线程验证依赖这一边界。
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    /// 一次性sending进入owner的Metal设备。
    private let device: any MTLDevice

    /// 接收已断开外部别名的设备，不创建显示目标。
    init(device: sending any MTLDevice) { self.device = device }

    /// 检查实际纹理格式、坐标、资源身份与跨帧留存；没有CPU像素读回。
    func verify(_ frame: VideoFrameTransfer) throws {
        #expect(!Thread.isMainThread)
        let resources = try MetalResources(device: device)
        var budget = try MetalFrameBudget()
        let input = try resources.video(frame, budget: &budget)
        #expect(input.luma.pixelFormat == .r8Unorm && input.chroma.pixelFormat == .rg8Unorm)
        #expect(input.luma.width == input.chroma.width * 2 && input.luma.height == input.chroma.height * 2)
        #expect(input.byteCost >= frame.byteCount + 1024)
        #expect(input.uniforms.colorRegion == SIMD4(Float(frame.size.width), Float(frame.size.height),
                                                    1 / Float(input.luma.width), 1 / Float(input.luma.height)))
        #expect(input.uniforms.alphaRegion.x == Float(frame.alphaStartX))
        #expect(input.uniforms.alphaRegion.y == Float(frame.alphaStartY))
        #expect(input.uniforms.alphaRegion.z == (frame.alphaStartX == 0 && frame.alphaStartY == 0 ? 0 : 1))
        #expect(MemoryLayout<MetalVideoUniforms>.stride == 32)
        #expect(try resources.video(frame, budget: &budget) === input)
        var next = try MetalFrameBudget()
        #expect(try resources.video(frame, budget: &next) === input)
        #expect(resources.count == 1 && resources.byteCount == input.byteCost)
        resources.removeAll()
        #expect(resources.count == 0 && resources.byteCount == 0)
        #expect(input.luma.width > 0 && input.chroma.height > 0)
        #expect(throws: PAGError.mediaFailure("videoFrameAlreadyConsumed")) { try frame.take() }
    }

    /// 单帧保活独立于LRU；预算释放后包装才能销毁，验证强引用没有从输入错误地扩散。
    func verifyUncached(_ frame: VideoFrameTransfer) throws {
        let resources = try MetalResources(device: device, byteLimit: 0)
        var tiny = try MetalFrameBudget(maximumBytes: 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumMetalFrameBytes")) { try resources.video(frame, budget: &tiny) }
        var budget: MetalFrameBudget? = try MetalFrameBudget()
        weak var observed: MetalVideoInput?
        do {
            var current = try #require(budget)
            let input = try resources.video(frame, budget: &current)
            observed = input
            budget = current
            #expect(resources.count == 0 && resources.byteCount == 0)
            #expect(try resources.video(frame, budget: &current) === input)
        }
        #expect(observed != nil)
        budget = nil
        #expect(observed == nil)
    }
}
