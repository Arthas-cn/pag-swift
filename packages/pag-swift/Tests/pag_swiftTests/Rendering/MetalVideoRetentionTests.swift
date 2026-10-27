import CoreMedia
import Foundation
import Metal
import Testing
import VideoToolbox
@testable import pag_swift

/// 顺序播放不应把历史NV12输入一直填入通用LRU；此组验证真实映射的缓存、预算与批次所有权。
@Suite(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) && MTLCreateSystemDefaultDevice() != nil,
                 "需要H.264硬件与Metal"), .timeLimit(.minutes(1)))
struct MetalVideoRetentionTests {
    /// 根帧完成准备只保留该帧的全部视频输入，重复PTS仍复用；清掉历史引用不破坏旧批次或图片LRU。
    @Test func keepsCurrentVideoFramesAndReleasesHistoryWithoutChangingImageCache() async throws {
        let file = try await VideoPlanningFixtures.nested(starts: [0, 1], opacity: 128)
        let scene = try await PreparedScene.prepare(file.composition)
        let earlier = try await VideoPlanningFixtures.plan(scene, frame: 2)
        let current = try await VideoPlanningFixtures.plan(scene, frame: 4)
        #expect(earlier.videos.count == 2 && current.videos.count == 2)
        #expect(Set(earlier.videos.keys).isDisjoint(with: current.videos.keys))
        let image = try await PAGImage.load(data: PAGFixtures.data(named: "media/rgba-corners.png"))
        let owner = CurrentVideoRetentionOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verify(earlier: earlier, current: current, size: file.composition.size, image: image)
    }

    /// 失败帧不提交缓存裁剪；前一成功帧继续可用，不因预算失败迫使已消费的输入重新导入。
    @Test func failedPreparationPreservesLastSuccessfulVideoInput() async throws {
        let file = try await VideoPlanningFixtures.nested(starts: [0])
        let scene = try await PreparedScene.prepare(file.composition)
        let earlier = try await VideoPlanningFixtures.plan(scene, frame: 2)
        let next = try await VideoPlanningFixtures.plan(scene, frame: 4)
        let owner = CurrentVideoRetentionOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifyFailedPreparation(earlier: earlier, next: next, size: file.composition.size)
    }
}

/// 当前测试独占裸Metal输入；只接收Sendable计划，不把纹理或系统缓冲跨actor暴露。
private actor CurrentVideoRetentionOwner {
    /// 一次性sending移交的真实设备。
    private let device: any MTLDevice

    /// 接管设备所有权，不创建窗口、drawable或另一条播放器链。
    init(device: sending any MTLDevice) { self.device = device }

    /// 比较真实映射身份和LRU计费，并用weak证明历史输入只活到旧批次释放。
    func verify(earlier: PreparedFrame, current: PreparedFrame, size: PAGSize, image: PAGImage) throws {
        let resources = try MetalResources(device: device)
        var imageBudget = try MetalFrameBudget()
        let texture = try resources.image(image, budget: &imageBudget)
        var earlierBatch: MetalFrameBatch? = try prepare(earlier, size: size, resources: resources)
        weak let oldInput = earlierBatch?.passes.flatMap(\.draws).compactMap(\.video).first
        var currentBatch: MetalFrameBatch? = try prepare(current, size: size, resources: resources)
        let preparedInputs = currentBatch?.passes.flatMap(\.draws).compactMap(\.video)
        let currentInputs = try #require(preparedInputs)
        #expect(currentInputs.count == 2)
        #expect(currentInputs[0] !== currentInputs[1])
        // 2个当前视频、1个单位矩形和1张图片；旧帧仍在批次中，但不能再占LRU计账。
        #expect(resources.count == 4)
        var meshBudget = try MetalFrameBudget()
        let mesh = try resources.rectangle(budget: &meshBudget)
        let expectedBytes = currentInputs.reduce(0) { $0 + $1.byteCost } + mesh.byteCost + image.storage.pixels.count + 512
        #expect(resources.byteCount == expectedBytes)
        #expect(oldInput?.luma.width ?? 0 > 0)
        earlierBatch?.releaseTransients()
        earlierBatch = nil
        #expect(oldInput == nil)

        // 同一已消费transfer再次准备必须命中当前缓存，不能重新take或重建CoreVideo映射。
        var repeatedBatch: MetalFrameBatch? = try prepare(current, size: size, resources: resources)
        let repeatedPreparedInputs = repeatedBatch?.passes.flatMap(\.draws).compactMap(\.video)
        let repeatedInputs = try #require(repeatedPreparedInputs)
        #expect(zip(currentInputs, repeatedInputs).allSatisfy { $0 === $1 })
        #expect(resources.byteCount == expectedBytes)
        repeatedBatch?.releaseTransients()
        repeatedBatch = nil
        currentBatch?.releaseTransients()
        currentBatch = nil

        let empty = PreparedFrame(plan: FramePlan(time: current.plan.time, targetBounds: current.plan.targetBounds, commands: []),
                                  images: [:], shapes: [:], texts: [:])
        let emptyBatch = try prepare(empty, size: size, resources: resources)
        defer { emptyBatch.releaseTransients() }
        #expect(resources.count == 2)
        #expect(resources.byteCount == mesh.byteCost + image.storage.pixels.count + 512)
        var nextImageBudget = try MetalFrameBudget()
        #expect(try resources.image(image, budget: &nextImageBudget) === texture)
    }

    /// 预算失败不能把上一帧缓存当成已过期；之后重绘该帧仍命中原有双平面输入。
    func verifyFailedPreparation(earlier: PreparedFrame, next: PreparedFrame, size: PAGSize) throws {
        let resources = try MetalResources(device: device)
        let batch = try prepare(earlier, size: size, resources: resources)
        defer { batch.releaseTransients() }
        let original = try #require(batch.passes.flatMap(\.draws).compactMap(\.video).first)
        let originalBytes = resources.byteCount
        #expect(throws: PAGError.resourceLimitExceeded("maximumMetalFrameBytes")) {
            try MetalFramePreparation.prepare(next, width: Int(size.width), height: Int(size.height),
                                             resources: resources, maximumBytes: 1)
        }
        #expect(resources.byteCount == originalBytes)
        let repeated = try prepare(earlier, size: size, resources: resources)
        defer { repeated.releaseTransients() }
        #expect(repeated.passes.flatMap(\.draws).compactMap(\.video).first === original)
    }

    /// 调用真实根帧准备入口；资源裁剪必须挂在此入口，而不是测试手动调用维护函数。
    private func prepare(_ frame: PreparedFrame, size: PAGSize, resources: MetalResources) throws -> MetalFrameBatch {
        try MetalFramePreparation.prepare(frame, width: Int(size.width), height: Int(size.height), resources: resources)
    }
}
