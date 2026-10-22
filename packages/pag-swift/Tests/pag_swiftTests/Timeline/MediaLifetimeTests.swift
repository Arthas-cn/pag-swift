import Metal
import Testing
@testable import pag_swift

/// 反复播放和替换真实动态素材时，核对媒体owner与Metal输入缓存的留存边界。
struct MediaLifetimeTests {
    /// 四轮GIF/WebP替换跨越约两分半的虚拟播放时间，旧帧与临时附件不随轮数累积。
    @Test func repeatedAnimatedReplacementKeepsCachesBounded() async throws {
        let source = try await ImageTimeFixtures.file(rule: nil, start: 0, duration: 1_200,
            offsets: [0], fileDuration: 1_200)
        let gif = try await PAGImage.load(data: PAGFixtures.data(named: "media/bear.gif"))
        let webp = try await PAGImage.load(data: PAGFixtures.data(named: "media/webp01.webp"))
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()),
            byteLimit: 16 * 1_024 * 1_024)
        _ = try resources.pipelines()
        var peakInputBytes = 0
        for replacement in [gif, webp, gif, webp] {
            var composition = source.composition
            try composition.replaceImage(replacement, at: 0)
            let scene = try await PreparedScene.prepare(composition)
            let store = try #require(scene.animatedImages)
            let frameBytes = Int(replacement.size.width * replacement.size.height) * 4
            for sample in 0..<60 {
                // 每次前进19个源帧，覆盖多轮循环和非顺序帧选择，而不依赖真实睡眠。
                let time = try SceneValidator.time(frame: Int64(sample * 19), rate: 30)
                let frame = try await FramePlanner.prepare(scene, at: time,
                    targetSize: scene.composition.size, scale: 1, mode: .none)
                let batch = try MetalFramePreparation.prepare(frame, width: 100, height: 80,
                    resources: resources, disablePictureCache: true)
                batch.releaseTransients()
                let retained = await store.retainedBytes()
                peakInputBytes = max(peakInputBytes, retained)
                #expect(retained <= frameBytes)
                #expect(resources.byteCount <= 16 * 1_024 * 1_024)
                #expect(resources.groups.activeBytes == 0)
                #expect(resources.pictures.activeBytes == 0)
            }
        }
        #expect(peakInputBytes > 0)
    }

    /// 真实MP4多次前后seek后，视频owner只保留当前NV12帧且不会逐次增长。
    @Test func repeatedVideoSeekKeepsOneInputFrame() async throws {
        let url = try PAGFixtures.rootURL().appendingPathComponent("game.mp4")
        let image = try await PAGImage.loadVideo(from: url)
        let source = try #require(image.video)
        let store = ExternalVideoFrameStore()
        var firstCost: Int?
        for sample in 0..<24 {
            let time = PAGTime(microseconds: sample.isMultiple(of: 2) ? 0 : 1_000_000)
            let transfer = try await store.frame(for: source, at: time)
            _ = try transfer.take()
            let retained = await store.retainedBytes()
            #expect(retained > 0 && retained <= 64 * 1_024 * 1_024)
            if let firstCost { #expect(retained == firstCost) }
            else { firstCost = retained }
        }
    }
}
