import CoreVideo
import Metal
import Testing
@testable import pag_swift

/// 真实game.mp4的公开工厂、局部时间seek及420v交接；不把AVFoundation状态当作PAG时钟。
struct ExternalVideoTests {
    /// 真实视频只公开有效可呈现尺寸和时长，不创建静图RGBA输入。
    @Test func realVideoFactoryValidatesTrack() async throws {
        let url = try PAGFixtures.rootURL().appendingPathComponent("game.mp4")
        let image = try await PAGImage.loadVideo(from: url)
        #expect(image.kind == .video)
        #expect(image.size == (try PAGSize(width: 1280, height: 720)))
        #expect(image.duration == PAGTime(microseconds: 9_525_000))
        #expect(image.storage.pixels.isEmpty)
        await #expect(throws: PAGError.mediaFailure("invalidImage")) {
            try await PAGImage.load(data: PAGFixtures.data(named: "game.mp4"))
        }
    }

    /// 0秒、1秒与末尾用系统NV12目标帧，回seek复现首帧且旧交接槽仍独立有效。
    @Test func actualFramesSeekAndHoldEnd() async throws {
        let url = try PAGFixtures.rootURL().appendingPathComponent("game.mp4")
        let image = try await PAGImage.loadVideo(from: url)
        let source = try #require(image.video)
        let store = ExternalVideoFrameStore()
        let first = try await store.frame(for: source, at: .zero)
        let later = try await store.frame(for: source, at: PAGTime(microseconds: 1_000_000))
        let held = try await store.frame(for: source, at: PAGTime(microseconds: 20_000_000))
        let seeked = try await store.frame(for: source, at: .zero)
        #expect(first.identity != later.identity)
        #expect(later.identity != held.identity)
        #expect(seeked.identity == first.identity)
        #expect(held.size == image.size)
        #expect(first.colorMatrix == .bt709 && later.colorMatrix == .bt709)
        #expect(await store.retainedBytes() > 0)
        let buffer = try first.take()
        let nextBuffer = try later.take()
        let restoredBuffer = try seeked.take()
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(CVPixelBufferGetPlaneCount(buffer) == 2)
        #expect(try sampledLuma(buffer) != sampledLuma(nextBuffer))
        #expect(try sampledLuma(buffer) == sampledLuma(restoredBuffer))
    }

    /// 单帧预算低于真实NV12平面成本时明确失败，owner不留存一张超额视频帧。
    @Test func frameBudgetRejectsOversizedOutput() async throws {
        let image = try await PAGImage.loadVideo(from: PAGFixtures.rootURL().appendingPathComponent("game.mp4"))
        let source = try #require(image.video)
        let store = ExternalVideoFrameStore(maximumBytes: 1_024)
        await #expect(throws: PAGError.resourceLimitExceeded("maximumVideoFrameBytes")) {
            try await store.frame(for: source, at: .zero)
        }
        #expect(await store.retainedBytes() == 0)
    }

    /// 图片槽替换的视频生成视频命令和裁剪，按层时间而非根时刻取帧。
    @Test func videoReplacementReachesFramePlan() async throws {
        let file = try await ImageTimeFixtures.file(rule: nil, start: 0, duration: 300,
            offsets: [0], fileDuration: 300)
        let image = try await PAGImage.loadVideo(from: PAGFixtures.rootURL().appendingPathComponent("game.mp4"))
        var composition = file.composition
        try composition.replaceImage(image, named: "image")
        let scene = try await PreparedScene.prepare(composition)
        let first = try await plan(scene, frame: 0)
        let later = try await plan(scene, frame: 30)
        let firstVideo = try #require(video(first))
        let nextVideo = try #require(video(later))
        #expect(firstVideo.resourceID != nextVideo.resourceID)
        #expect(firstVideo.clip != nil && nextVideo.clip != nil)
        #expect(first.videos[firstVideo.resourceID]?.size == image.size)
        #expect(later.videos[nextVideo.resourceID]?.colorMatrix == .bt709)
        #expect(first.images.isEmpty && later.images.isEmpty)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        _ = try resources.pipelines()
        let batch = try MetalFramePreparation.prepare(first, width: 100, height: 80,
            resources: resources, disablePictureCache: true)
        #expect(batch.passes.last?.attachment == nil)
        #expect(batch.passes.last?.draws.contains(where: { $0.video != nil }) == true)
        batch.releaseTransients()
        #expect(resources.groups.activeBytes == 0)
        var byIndex = file.composition
        try byIndex.replaceImage(image, at: 0)
        let indexed = try await plan(PreparedScene.prepare(byIndex), frame: 0)
        #expect(video(indexed)?.resourceID == firstVideo.resourceID)
    }

    /// 读取真实计划的视频命令，不以媒体owner有缓冲代替显示接线。
    private func video(_ frame: PreparedFrame) -> FrameVideo? {
        for command in frame.plan.commands {
            if case .video(let value) = command { return value }
        }
        return nil
    }

    /// 以文件根帧率提交计划，让生产图层时钟完成素材采样。
    private func plan(_ scene: PreparedScene, frame: Int64) async throws -> PreparedFrame {
        let root = scene.composition.storage.compositions[scene.composition.storage.rootIndex]
        return try await FramePlanner.prepare(scene, at: SceneValidator.time(frame: frame, rate: root.frameRate),
            targetSize: scene.composition.size, scale: 1, mode: .none)
    }

    /// 测试中少量抽样系统输入亮度，证明seek返回真实不同/相同像素；生产路径不锁CPU地址。
    private func sampledLuma(_ buffer: CVPixelBuffer) throws -> [UInt8] {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw PAGError.mediaFailure("testVideoLock")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            throw PAGError.mediaFailure("testVideoLuma")
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        return stride(from: 16, to: height, by: 64).flatMap { y in
            stride(from: 16, to: width, by: 64).map { x in bytes[y * row + x] }
        }
    }
}
