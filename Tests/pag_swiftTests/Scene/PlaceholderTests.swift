import Testing
@testable import pag_swift

/// 图片槽占位的COW编辑、素材约束和首次有效提交后才启动的辅助时间。
struct PlaceholderTests {
    /// 索引命中共享实例，名称只命中同名图片；非法输入不能部分修改原快照。
    @Test func indexedAndNamedPlaceholdersAreAtomic() async throws {
        let file = try await EditableFixtures.file()
        let still = try await PAGImage.load(data: PAGFixtures.data(named: "media/imageReplacement.png"))
        let animated = try await PAGImage.load(data: PAGFixtures.data(named: "media/bear.gif"))
        let video = try await PAGImage.loadVideo(from: PAGFixtures.rootURL().appendingPathComponent("game.mp4"))
        var edited = file.composition
        let original = edited
        try edited.setPlaceholder(still, at: 1)
        #expect(edited.edits.placeholders.count > 1)
        #expect(original.edits.placeholders.isEmpty)
        try edited.setPlaceholder(animated, named: "shared")
        for layer in edited.layers(named: "shared") where layer.kind == .image {
            #expect(edited.edits.placeholders[layer.id]?.kind == .animated)
        }
        #expect(throws: PAGError.invalidArgument("placeholder")) {
            try edited.setPlaceholder(video, at: 1)
        }
        #expect(throws: PAGError.noMatchingImageLayer("missing")) {
            try edited.setPlaceholder(still, named: "missing")
        }
        #expect(edited.edits.placeholders.count > 1)
        try edited.setPlaceholder(nil, named: "shared")
        #expect(edited.layers(named: "shared").allSatisfy {
            $0.kind != .image || edited.edits.placeholders[$0.id] == nil
        })
        edited.resetEdits()
        #expect(edited.edits.placeholders.isEmpty)
    }

    /// 计划读取不启动占位，GPU成功提交才建立零点；停用后再次出现重新从首帧起计。
    @Test func clockStartsOnlyOnValidActivation() async throws {
        let file = try await EditableFixtures.file()
        let id = try #require(file.composition.layers(named: "shared").first { $0.kind == .image }?.id)
        let clock = PresentationActivationClock()
        #expect(clock.elapsed(for: id, at: PAGTime(microseconds: 1_000_000)) == .zero)
        #expect(clock.elapsed(for: id, at: PAGTime(microseconds: 1_500_000)) == .zero)
        clock.activate([id], at: PAGTime(microseconds: 1_500_000))
        #expect(clock.elapsed(for: id, at: PAGTime(microseconds: 1_700_000)) == PAGTime(microseconds: 200_000))
        clock.activate([id], at: PAGTime(microseconds: 1_900_000))
        #expect(clock.elapsed(for: id, at: PAGTime(microseconds: 2_000_000)) == PAGTime(microseconds: 500_000))
        clock.deactivate(id)
        #expect(clock.elapsed(for: id, at: PAGTime(microseconds: 2_100_000)) == .zero)
    }

    /// 视频首帧尚不可用时选择真实 GIF 完整画布，实际呈现激活后跨 seek 按辅助时间推进。
    @Test func animatedPlaceholderUsesActiveTimeAfterPendingVideo() async throws {
        let file = try await ImageTimeFixtures.file(rule: nil, start: 0, duration: 30,
            offsets: [0], fileDuration: 30)
        let video = try await PAGImage.loadVideo(from: PAGFixtures.rootURL().appendingPathComponent("game.mp4"))
        let gif = try await PAGImage.load(data: PAGFixtures.data(named: "media/bear.gif"))
        var edited = file.composition
        try edited.replaceImage(video, at: 0)
        try edited.setPlaceholder(gif, at: 0)
        let scene = try await PreparedScene.prepare(edited, externalVideoSampler: PendingVideoSampler())
        let first = try await plan(scene, frame: 0, active: 1_000_000)
        let firstID = try #require(imageID(first))
        #expect(first.videos.isEmpty && first.placeholderIDs.count == 1)
        #expect(first.images[firstID]?.storage.pixels.count == Int(gif.size.width * gif.size.height) * 4)
        scene.placeholderClock?.activate(first.placeholderIDs, at: PAGTime(microseconds: 1_000_000))
        let later = try await plan(scene, frame: 5, active: 1_200_000)
        let laterID = try #require(imageID(later))
        #expect(firstID != laterID)
        let seeked = try await plan(scene, frame: 0, active: 1_200_000)
        #expect(imageID(seeked) == laterID)
    }

    /// 已明确选择的视频首帧待交付而未设置占位时，该图片槽透明，不能闪回原始图片或阻断整帧。
    @Test func pendingVideoWithoutPlaceholderLeavesTransparentSlot() async throws {
        let file = try await ImageTimeFixtures.file(rule: nil, start: 0, duration: 30,
            offsets: [0], fileDuration: 30)
        let video = try await PAGImage.loadVideo(from: PAGFixtures.rootURL().appendingPathComponent("game.mp4"))
        var edited = file.composition
        try edited.replaceImage(video, at: 0)
        let scene = try await PreparedScene.prepare(edited, externalVideoSampler: PendingVideoSampler())
        let result = try await plan(scene, frame: 0, active: 0)
        #expect(result.images.isEmpty && result.videos.isEmpty && result.placeholderIDs.isEmpty)
        #expect(imageID(result) == nil)
    }

    /// 可选视频终态失败只记录并请求一次，后续帧沿同一占位继续播放且不重试坏解码器。
    @Test func fatalOptionalVideoFailureUsesPlaceholderOnce() async throws {
        let file = try await ImageTimeFixtures.file(rule: nil, start: 0, duration: 30,
            offsets: [0], fileDuration: 30)
        let video = try await PAGImage.loadVideo(from: PAGFixtures.rootURL().appendingPathComponent("game.mp4"))
        let still = try await PAGImage.load(data: PAGFixtures.data(named: "media/imageReplacement.png"))
        var edited = file.composition
        try edited.replaceImage(video, at: 0)
        try edited.setPlaceholder(still, at: 0)
        let sampler = FailingVideoSampler()
        let scene = try await PreparedScene.prepare(edited, externalVideoSampler: sampler)
        let first = try await plan(scene, frame: 0, active: 0)
        let second = try await plan(scene, frame: 1, active: 100_000)
        let id = try #require(first.placeholderIDs.first)
        #expect(first.videos.isEmpty && second.videos.isEmpty)
        #expect(imageID(first) == still.storage.identity && imageID(second) == still.storage.identity)
        #expect(scene.optionalMediaFailures.failure(for: id) == .mediaFailure("decoderStopped"))
        #expect(await sampler.calls == 1)
    }

    /// 用生产帧规划读取占位实际输入身份，避免只检查编辑表。
    private func imageID(_ frame: PreparedFrame) -> DocumentIdentity? {
        for command in frame.plan.commands {
            if case .image(let value) = command { return value.resourceID }
        }
        return nil
    }

    /// 传入独立累计播放时间，根帧变化由正式图片层时钟处理。
    private func plan(_ scene: PreparedScene, frame: Int64, active: Int64) async throws -> PreparedFrame {
        let root = scene.composition.storage.compositions[scene.composition.storage.rootIndex]
        return try await FramePlanner.prepare(scene, at: SceneValidator.time(frame: frame, rate: root.frameRate),
            targetSize: scene.composition.size, scale: 1, mode: .none,
            auxiliaryTime: PAGTime(microseconds: active))
    }
}

/// 可控系统首帧延迟，只模拟真实AVPlayerItemVideoOutput的暂不可用结果。
private actor PendingVideoSampler: ExternalVideoSampling {
    /// 图片层应选择占位而非闪回原始图；不会发布假视频帧。
    func frame(for source: ExternalVideoStorage, at time: PAGTime,
               isPlaying: Bool) async throws -> VideoFrameTransfer {
        throw PAGError.mediaFailure("externalVideoNotReady")
    }

    /// 假采样器没有系统预取，暂停不改变后续受控结果。
    func pause() async {}
}

/// 注入可选媒体的终态失败，确认主PAG帧继续且后续请求不会重复进入坏会话。
private actor FailingVideoSampler: ExternalVideoSampling {
    /// 生产帧规划实际调用媒体owner的次数。
    private(set) var calls = 0

    /// 模拟系统视频首帧永久失败，不发布假输入。
    func frame(for source: ExternalVideoStorage, at time: PAGTime,
               isPlaying: Bool) async throws -> VideoFrameTransfer {
        calls += 1
        throw PAGError.mediaFailure("decoderStopped")
    }

    /// 失败采样器无系统会话，暂停只满足同一正式协议。
    func pause() async {}
}
