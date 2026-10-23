import Testing
@testable import pag_swift

/// 真实 GIF/WebP 的逐帧像素、循环和独立进度，不用模拟的容器元数据代替解码。
struct AnimatedImageTests {
    /// 两种真实动图在帧边界取不同RGBA，重复采样复用帧，循环后回到第一帧。
    @Test(arguments: ["bear.gif", "webp01.webp"])
    func realFramesAdvanceAndLoop(_ name: String) async throws {
        let image = try await PAGImage.load(data: PAGFixtures.data(named: "media/\(name)"))
        let animation = try #require(image.animation)
        let store = AnimatedImageFrameStore()
        let first = try await store.frame(for: image, at: .zero)
        let next = try await store.frame(for: image, at: PAGTime(microseconds: animation.ends[0]))
        #expect(first.storage.identity != next.storage.identity)
        #expect(first.storage.pixels != next.storage.pixels)
        #expect(next.storage.pixels.count == first.storage.pixels.count)
        let repeated = try await store.frame(for: image, at: PAGTime(microseconds: animation.durationMicroseconds))
        #expect(repeated.storage.identity == first.storage.identity)
        #expect(repeated.storage.pixels == first.storage.pixels)
        #expect(await store.retainedBytes() == first.storage.pixels.count)
    }

    /// 有限循环播满后保持末帧；准确边界切到下一帧且负时间落在首帧。
    @Test func finitePlaybackAndFrameBoundaries() async throws {
        let image = try await PAGImage.load(data: PAGFixtures.data(named: "media/webp01.webp"))
        let source = try #require(image.animation)
        let finite = try AnimatedImageStorage(identity: source.identity, data: source.data,
            sourceType: source.sourceType, ends: source.ends, playCount: 2, size: source.size)
        #expect(finite.frameIndex(at: PAGTime(microseconds: -1)) == 0)
        #expect(finite.frameIndex(at: PAGTime(microseconds: source.ends[0] - 1)) == 0)
        #expect(finite.frameIndex(at: PAGTime(microseconds: source.ends[0])) == 1)
        #expect(finite.frameIndex(at: PAGTime(microseconds: source.durationMicroseconds)) == 0)
        #expect(finite.frameIndex(at: PAGTime(microseconds: source.durationMicroseconds * 2)) == source.ends.count - 1)
    }

    /// 优化GIF的局部帧、透明像素和恢复背景处置须得到整幅合成帧；无循环扩展只播放一次。
    @Test func optimizedGIFComposesPartialTransparentAndDisposedFrames() async throws {
        let image = try await PAGImage.load(data: PAGFixtures.data(named: "media/optimized-disposal.gif"))
        let animation = try #require(image.animation)
        #expect(animation.ends == [100_000, 200_000, 300_000, 400_000])
        #expect(animation.playCount == 1)
        let store = AnimatedImageFrameStore()
        let expected: [[UInt8]] = [
            [255, 0, 0, 255, 255, 0, 0, 255],
            [255, 0, 0, 255, 0, 0, 255, 255],
            [255, 0, 0, 255, 0, 255, 0, 255],
            [0, 0, 255, 255, 0, 0, 0, 255]
        ]
        for (index, pixels) in expected.enumerated() {
            let frame = try await store.frame(for: image, at: PAGTime(microseconds: Int64(index) * 100_000))
            #expect(Array(frame.storage.pixels) == pixels)
        }
        let held = try await store.frame(for: image, at: PAGTime(microseconds: 500_000))
        #expect(Array(held.storage.pixels) == expected[3])
    }

    /// 动图单帧峰值超过媒体owner预算时拒绝解码且不留存旧/半帧。
    @Test func animatedFrameBudgetRejectsOversizedCanvas() async throws {
        let image = try await PAGImage.load(data: PAGFixtures.data(named: "media/bear.gif"))
        let store = AnimatedImageFrameStore(maximumBytes: 1_024)
        await #expect(throws: PAGError.resourceLimitExceeded("maximumAnimatedFrameBytes")) {
            try await store.frame(for: image, at: .zero)
        }
        #expect(await store.retainedBytes() == 0)
    }

    /// 图层替换用独立累计时间推进动图；PAG 反向 seek 不回拨动图，旧计划仍保有旧帧。
    @Test func replacementUsesIndependentTimeAcrossRootSeek() async throws {
        let file = try await ImageTimeFixtures.file(rule: nil, start: 0, duration: 30,
            offsets: [0], fileDuration: 30)
        let image = try await PAGImage.load(data: PAGFixtures.data(named: "media/bear.gif"))
        var composition = file.composition
        try composition.replaceImage(image, at: 0)
        let scene = try await PreparedScene.prepare(composition)
        let first = try await plan(scene, frame: 0, imageTime: .zero)
        let later = try await plan(scene, frame: 5, imageTime: PAGTime(microseconds: 166_666))
        let seeked = try await plan(scene, frame: 0, imageTime: PAGTime(microseconds: 166_666))
        let firstID = try #require(firstImageID(first))
        let laterID = try #require(firstImageID(later))
        #expect(firstID != laterID)
        #expect(laterID == firstImageID(seeked))
        #expect(first.images[firstID]?.storage.pixels != later.images[laterID]?.storage.pixels)
        #expect(later.images[laterID]?.storage.pixels == seeked.images[laterID]?.storage.pixels)
    }

    /// 从完整生产帧计划中读取首个图片命令的输入身份。
    private func firstImageID(_ frame: PreparedFrame) -> DocumentIdentity? {
        for command in frame.plan.commands {
            if case .image(let image) = command { return image.resourceID }
        }
        return nil
    }

    /// 分别传根帧位置与已累计的动图时间，避免把两者错误绑定。
    private func plan(_ scene: PreparedScene, frame: Int64, imageTime: PAGTime) async throws -> PreparedFrame {
        let root = scene.composition.storage.compositions[scene.composition.storage.rootIndex]
        return try await FramePlanner.prepare(scene, at: SceneValidator.time(frame: frame, rate: root.frameRate),
            targetSize: scene.composition.size, scale: 1, mode: .none, imageAnimationTime: imageTime)
    }
}
