import Foundation
import Synchronization
import Testing
@testable import pag_swift

/// 第三方无关的完整帧入口复用现有媒体时序与有界缓存；这里不冒充 SDWebImage 整链路验收。
struct HostAnimatedImageTests {
    /// 明确选择静态时只复用工厂首帧，不创建动图 owner；原素材仍可在另一槽独立播放。
    @Test func explicitStillModePreservesPosterWithoutMutatingSharedAnimation() async throws {
        let file = try await EditableFixtures.file()
        let source = try HostFrameFixture()
        let image = try await PAGImage.animated(from: source)
        var composition = file.composition
        try await composition.apply(.image(image, options: PAGImageContentOptions(playbackMode: .still)),
                                    forTag: "image:0")
        let stillScene = try await PreparedScene.prepare(composition)
        #expect(stillScene.animatedImages == nil)
        let still = try #require(composition.edits.images.values.first)
        #expect(still.kind == .still && still.duration == nil)
        #expect(still.storage.identity == image.storage.identity)
        #expect(still.storage.pixels == image.storage.pixels)
        #expect(source.requested == [0])
        try await composition.apply(.image(image), forTag: "image:1")
        let mixed = try await PreparedScene.prepare(composition)
        #expect(mixed.animatedImages != nil)
        #expect(composition.edits.images.values.filter { $0.kind == .animated }.count == 4)
        #expect(composition.edits.images.values.filter { $0.kind == .still }.count == 1)
        #expect(image.kind == .animated)
        #expect(source.requested == [0])
    }

    /// URL 供给经过播放器异步解析后仍保留静态选项，诊断记录实际静图类型且后续不读取动态帧。
    @Test(.timeLimit(.minutes(1))) func explicitStillModeSurvivesURLProvider() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/ImageDecodeTest.pag"))
        let tag = try #require(file.contentSlots.first?.tag)
        let source = try HostFrameFixture()
        let image = try await PAGImage.animated(from: source)
        let player = PAGPlayer()
        try await player.setComposition(file.composition)
        var events = await player.contentUpdates().makeAsyncIterator()
        try await player.setContentProvider({ slot in
            slot.tag == tag ? .imageURL(URL(fileURLWithPath: "/fixture.gif"),
                options: PAGImageContentOptions(playbackMode: .still)) : .unchanged
        }, loadImageFromURL: { _ in image })
        while let event = await events.next() {
            if event.status == .applied, event.tag == tag {
                #expect(event.tag == tag && event.contentType == "image.still")
                break
            }
            #expect(event.status != .failed)
        }
        let content = try #require(await player.contentComposition)
        #expect(!content.edits.images.isEmpty)
        #expect(content.edits.images.values.allSatisfy { $0.kind == .still })
        #expect(source.requested == [0])
    }

    /// 两个槽位交替采样同一素材帧时，各解码一次；一方换帧不会驱逐另一方仍有效的当前帧。
    @Test func multipleMaterialsKeepTheirCurrentFrames() async throws {
        let sources = try [HostFrameFixture(), HostFrameFixture(offset: 10)]
        var images: [PAGImage] = []
        for source in sources { images.append(try await PAGImage.animated(from: source)) }
        let owner = AnimatedImageFrameStore()
        for _ in 0..<10 {
            for image in images { _ = try await owner.frame(for: image, at: PAGTime(microseconds: 100_000)) }
        }
        #expect(sources.allSatisfy { $0.requested == [0, 1] })
        _ = try await owner.frame(for: images[0], at: PAGTime(microseconds: 300_000))
        _ = try await owner.frame(for: images[1], at: PAGTime(microseconds: 100_000))
        #expect(sources[0].requested == [0, 1, 2])
        #expect(sources[1].requested == [0, 1])
        #expect(await owner.retainedBytes() == 16)
    }

    /// 多素材缓存同时受总解码峰值和十六项上限约束；预算不足先淘汰最久未用项。
    @Test func multipleMaterialCacheHonorsByteAndEntryLimits() async throws {
        var sources: [HostFrameFixture] = []
        var images: [PAGImage] = []
        for offset: UInt8 in 0..<17 {
            let source = try HostFrameFixture(offset: offset)
            sources.append(source)
            images.append(try await PAGImage.animated(from: source))
        }
        let owner = AnimatedImageFrameStore()
        for image in images { _ = try await owner.frame(for: image, at: .zero) }
        #expect(await owner.retainedBytes() == 16 * 8)
        _ = try await owner.frame(for: images[1], at: .zero)
        #expect(sources[1].requested == [0, 0])
        _ = try await owner.frame(for: images[0], at: .zero)
        #expect(sources[0].requested == [0, 0, 0])

        let small = AnimatedImageFrameStore(maximumBytes: 24)
        for image in images { _ = try await small.frame(for: image, at: .zero) }
        #expect(await small.retainedBytes() == 8)
    }

    /// 只读取首帧建立素材，随后按不等长帧和有限循环采样，透明像素保持预乘输入。
    @Test func hostSourceUsesDurationsLoopsAndBoundedFrames() async throws {
        let source = try HostFrameFixture()
        let image = try await PAGImage.animated(from: source)
        #expect(image.kind == .animated && image.duration?.microseconds == 600_000)
        #expect(source.requested == [0])
        let owner = AnimatedImageFrameStore()
        let first = try await owner.frame(for: image, at: PAGTime(microseconds: 99_999))
        let second = try await owner.frame(for: image, at: PAGTime(microseconds: 100_000))
        let third = try await owner.frame(for: image, at: PAGTime(microseconds: 300_000))
        #expect(first.storage.pixels.first == 1)
        #expect(second.storage.pixels.first == 2)
        #expect(third.storage.pixels.first == 3)
        #expect(third.storage.pixels[7] == 0)
        #expect(try await owner.frame(for: image, at: PAGTime(microseconds: 600_000)).storage.pixels.first == 1)
        #expect(try await owner.frame(for: image, at: PAGTime(microseconds: 1_200_000)).storage.pixels.first == 3)
        #expect(try await owner.frame(for: image, at: PAGTime(microseconds: 100_000)).storage.pixels.first == 2)
        #expect(await owner.retainedBytes() == 8)
    }

    /// 暂不可用只保持本素材最近帧；切换不同源后不能显示之前素材的旧帧。
    @Test func unavailableFrameCannotLeakPreviousMaterial() async throws {
        let source = try HostFrameFixture()
        let image = try await PAGImage.animated(from: source)
        let owner = AnimatedImageFrameStore()
        _ = try await owner.frame(for: image, at: PAGTime(microseconds: 100_000))
        source.unavailable.withLock { $0 = true }
        #expect(try await owner.frame(for: image, at: PAGTime(microseconds: 300_000)).storage.pixels.first == 2)
        let other = try HostFrameFixture(offset: 10)
        let replacement = try await PAGImage.animated(from: other)
        other.unavailable.withLock { $0 = true }
        #expect(try await owner.frame(for: replacement, at: PAGTime(microseconds: 100_000)).storage.pixels.first == 11)
        #expect(source.requested.count < 8)
    }

    /// 宿主后续帧解码失败保留同素材最近帧并报告错误，换素材只能回退新首帧。
    @Test func decoderFailureFallsBackWithoutStoppingPAG() async throws {
        let source = try HostFrameFixture()
        let image = try await PAGImage.animated(from: source)
        let owner = AnimatedImageFrameStore()
        _ = try await owner.frame(for: image, at: PAGTime(microseconds: 100_000))
        source.fails.withLock { $0 = true }
        #expect(try await owner.frame(for: image, at: PAGTime(microseconds: 300_000)).storage.pixels.first == 2)
        let other = try HostFrameFixture(offset: 20)
        let replacement = try await PAGImage.animated(from: other)
        other.fails.withLock { $0 = true }
        #expect(try await owner.frame(for: replacement, at: PAGTime(microseconds: 300_000)).storage.pixels.first == 21)
        let report = await owner.diagnostics
        #expect(report.hostFailures == 2)
        #expect(report.lastHostFailure?.contains("decodeFailed") == true)
    }

    /// 单帧源归一为静图，动图元数据和画布不合法时在提交前明确拒绝。
    @Test func singleFrameAndInvalidMetadata() async throws {
        let single = try HostFrameFixture(singleFrame: true)
        let image = try await PAGImage.animated(from: single)
        #expect(image.kind == .still && image.duration == nil)
        #expect(throws: PAGError.invalidArgument("imageFramePixels")) {
            try PAGImageFrame(width: 2, height: 1, pixels: Data([0]))
        }
        #expect(throws: PAGError.invalidArgument("animatedFrameDuration")) {
            try PAGAnimatedImageInfo(size: PAGSize(width: 1, height: 1), frameDurations: [.zero])
        }
        #expect(throws: PAGError.invalidArgument("animatedPlayCount")) {
            try PAGAnimatedImageInfo(size: PAGSize(width: 1, height: 1),
                frameDurations: [PAGTime(microseconds: 1)], playCount: 0)
        }
        let owner = AnimatedImageFrameStore(maximumBytes: 1)
        let animated = try await PAGImage.animated(from: HostFrameFixture())
        await #expect(throws: PAGError.resourceLimitExceeded("maximumAnimatedFrameBytes")) {
            try await owner.frame(for: animated, at: .zero)
        }
    }

    /// tag 应用后仍保留宿主逐帧源，真实 PAG 的准备场景使用同一媒体 owner 消费不同完整帧。
    @Test func tagPreservesHostAnimation() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/ImageDecodeTest.pag"))
        let tag = try #require(file.contentSlots.first?.tag)
        let source = try HostFrameFixture()
        let image = try await PAGImage.animated(from: source)
        var composition = file.composition
        try await composition.apply(.image(image), forTag: tag)
        let scene = try await PreparedScene.prepare(composition)
        #expect(scene.animatedImages != nil)
        #expect(composition.edits.images.values.allSatisfy { $0.kind == .animated })
        #expect(composition.edits.visibility.isEmpty)
        let owner = try #require(scene.animatedImages)
        let first = try await owner.frame(for: image, at: .zero)
        let second = try await owner.frame(for: image, at: PAGTime(microseconds: 100_000))
        #expect(first.storage.identity != second.storage.identity)
        #expect(first.storage.pixels != second.storage.pixels)
    }
}

/// 小画布语义帧源；用 Mutex 明确同步测试读取与暂不可用开关。
private final class HostFrameFixture: PAGAnimatedImageSource {
    /// 全生命周期不变的两像素画布和帧时间表。
    let info: PAGAnimatedImageInfo
    /// 每个源使用不同的颜色偏移，便于发现跨素材旧帧污染。
    let offset: UInt8
    /// 模拟帧暂未准备好，与网络下载完全无关。
    let unavailable = Mutex(false)
    /// 模拟工厂成功后后续帧读取失败，不能让整个 PAG 播放失败。
    let fails = Mutex(false)
    /// 已请求帧号，证明工厂不会无界预解全部帧。
    private let indices = Mutex<[Int]>([])
    /// 当前实际请求序列的不可变快照。
    var requested: [Int] { indices.withLock { $0 } }

    /// 三帧总长 0.6 秒且播放两轮，或单帧静图，用于采样边界测试。
    init(offset: UInt8 = 0, singleFrame: Bool = false) throws {
        self.offset = offset
        info = try PAGAnimatedImageInfo(size: PAGSize(width: 2, height: 1),
            frameDurations: singleFrame ? [PAGTime(microseconds: 100_000)] :
                [100_000, 200_000, 300_000].map { PAGTime(microseconds: $0) }, playCount: 2)
    }

    /// 返回一色像素和全透明像素组成的完整画布；没有 patch/disposal 语义。
    func frame(at index: Int) throws -> PAGImageFrame? {
        indices.withLock { $0.append(index) }
        if fails.withLock({ $0 }) { throw PAGError.mediaFailure("decodeFailed") }
        if unavailable.withLock({ $0 }) { return nil }
        return try PAGImageFrame(width: 2, height: 1,
            pixels: Data([UInt8(index + 1) + offset, 0, 0, 255, 0, 0, 0, 0]))
    }
}
