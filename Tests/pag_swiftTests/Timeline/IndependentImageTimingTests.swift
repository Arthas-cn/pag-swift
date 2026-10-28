import Foundation
import Testing
@testable import pag_swift

/// GIF/WebP 源槽的独立进度：根循环、seek 和回卷不回拨，只有播放暂停与素材生命周期控制它。
struct IndependentImageTimingTests {
    /// 真实 player 在根时间恰好相同的循环边界仍发出新动图进度；暂停 seek 和换素材都正确装入后台请求。
    @Test(.timeLimit(.minutes(1))) func playerCarriesIndependentTimeAndStartsOnlyChangedMaterial() async throws {
        let composition = try await scene().composition
        let tag = try #require(composition.contentSlots.first?.tag)
        let rig = PlaybackTestRig()
        var requests = rig.probe.requests.makeAsyncIterator()
        var events = rig.events.makeAsyncIterator()
        try await rig.controller.setComposition(composition)
        await rig.controller.setRepeatCount(0)
        await rig.controller.updateTarget(.available)
        let initial = try #require(await requests.next())
        try await rig.controller.play()
        rig.clock.set(2_000_000)
        await rig.controller.tick(at: 2_000_000)
        try await rig.probe.complete(initial)
        let looped = try #require(await requests.next())
        #expect(looped.time == .zero && looped.imageAnimationTime.microseconds == 2_000_000)
        let frame = try await FramePlanner.prepare(#require(looped.scene), at: looped.time,
            targetSize: composition.size, scale: 1, mode: .none, imageAnimationTime: looped.imageAnimationTime)
        #expect(frame.images.values.first?.storage.pixels.first == 3)
        rig.clock.set(2_250_000)
        await rig.controller.pause()
        try await rig.probe.complete(looped)
        let paused = try #require(await requests.next())
        #expect(paused.imageAnimationTime.microseconds == 2_250_000)
        rig.clock.set(10_000_000)
        try await rig.controller.seek(to: PAGTime(microseconds: 1_500_000))
        try await rig.probe.complete(paused)
        let seeked = try #require(await requests.next())
        #expect(seeked.imageAnimationTime == paused.imageAnimationTime)
        try await rig.controller.rewind()
        try await rig.probe.complete(seeked)
        let rewound = try #require(await requests.next())
        #expect(rewound.imageAnimationTime == paused.imageAnimationTime && rewound.time == .zero)
        try await rig.probe.complete(rewound)
        try await PlaybackTestRig.wait(for: .workFinished(rewound.token.requestID, accepted: true), in: &events)
        var contentEvents = await rig.controller.contentUpdates().makeAsyncIterator()
        let image = try await PAGImage.animated(from: FourSecondImageSource())
        try await rig.controller.updateContent(.image(image), forTag: tag)
        while let event = await contentEvents.next(isolation: #isolation) {
            if event.status == .applied { break }
            #expect(event.status != .failed)
        }
        let replaced = try #require(await requests.next())
        let changed = try #require(replaced.scene)
        for id in changed.composition.edits.images.keys {
            #expect(changed.imageAnimationTimeline.elapsed(for: id, at: replaced.imageAnimationTime) == .zero)
        }
        try await rig.probe.complete(replaced)
        try await PlaybackTestRig.wait(for: .workFinished(replaced.token.requestID, accepted: true), in: &events)
    }

    /// 两秒 PAG 进入第二轮时，四秒动图到第三帧（50%），不能跟随根时间回到首帧。
    @Test func twoSecondPAGLoopKeepsFourSecondImageAtHalfProgress() async throws {
        let scene = try await scene()
        var timeline = try timeline()
        let first = try await pixels(scene, timeline: timeline)
        timeline.advance(to: 2_000_000)
        #expect(timeline.position == .zero && timeline.completedIterations == 1)
        #expect(timeline.imageElapsed == 2_000_000)
        #expect(first == 1)
        #expect(try await pixels(scene, timeline: timeline) == 3)
        timeline.advance(to: 3_000_000)
        #expect(try await pixels(scene, timeline: timeline) == 4)
        timeline.advance(to: 4_000_000)
        #expect(try await pixels(scene, timeline: timeline) == 1)
    }

    /// 暂停、后台挂起都冻结动图；seek/回卷只改变 PAG，恢复后接着原进度播放。
    @Test func pauseSeekRewindAndSuspensionPreserveImageProgress() async throws {
        let scene = try await scene()
        var timeline = try timeline()
        timeline.pause(at: 1_250_000)
        try timeline.seek(to: PAGTime(microseconds: 1_900_000), at: 10_000_000)
        try timeline.rewind(at: 11_000_000)
        #expect(timeline.activeElapsed == 0 && timeline.imageElapsed == 1_250_000)
        #expect(try await pixels(scene, timeline: timeline) == 2)
        try timeline.play(at: 12_000_000)
        timeline.setTarget(.unavailable, at: 12_500_000)
        timeline.advance(to: 30_000_000)
        #expect(timeline.imageElapsed == 1_750_000)
        timeline.setTarget(.available, at: 40_000_000)
        timeline.advance(to: 40_250_000)
        #expect(timeline.imageElapsed == 2_000_000)
        #expect(try await pixels(scene, timeline: timeline) == 3)
    }

    /// 播放中的 seek 与回卷会结算上个 tick 后经过的时间，但不会给动图加上 seek 的距离。
    @Test func controlCommandsCreditElapsedTimeWithoutUsingSeekDistance() throws {
        var timeline = try timeline()
        timeline.advance(to: 500_000)
        try timeline.seek(to: PAGTime(microseconds: 1_900_000), at: 750_000)
        #expect(timeline.imageElapsed == 750_000)
        try timeline.seek(to: .zero, at: 900_000)
        #expect(timeline.imageElapsed == 900_000)
        try timeline.rewind(at: 1_000_000)
        #expect(timeline.imageElapsed == 1_000_000)
        try timeline.install(duration: PAGTime(microseconds: 2_000_000))
        #expect(timeline.imageElapsed == 0)
    }

    /// 有限 PAG 结束后冻结动图，再次 play 续播；动图自己的有限轮数播满后保持末帧。
    @Test func rootReplayResumesImageAndImageFiniteLoopHoldsItsLastFrame() async throws {
        let scene = try await scene(playCount: 1)
        var timeline = try timeline(repeatCount: 1)
        timeline.advance(to: 2_000_000)
        timeline.didSubmitFinalFrame()
        #expect(try await pixels(scene, timeline: timeline) == 3)
        timeline.advance(to: 20_000_000)
        #expect(timeline.imageElapsed == 2_000_000)
        try timeline.play(at: 20_000_000)
        timeline.advance(to: 22_000_000)
        #expect(try await pixels(scene, timeline: timeline) == 4)
        timeline.didSubmitFinalFrame()
        try timeline.play(at: 23_000_000)
        timeline.advance(to: 24_000_000)
        #expect(try await pixels(scene, timeline: timeline) == 4)
    }

    /// 同源多实例共享安装起点；换另一个 tag、隐藏或恢复显示不改变既有素材进度。
    @Test func differentTagsKeepIndependentInstallationOrigins() async throws {
        let file = try await EditableFixtures.file()
        let slots = file.contentSlots.filter { $0.kind == .image }
        #expect(slots.count == 2)
        let image = try await PAGImage.animated(from: FourSecondImageSource())
        var composition = file.composition
        try await composition.apply(.image(image), forTag: slots[0].tag)
        var first = try await PreparedScene.prepare(composition)
        first.imageAnimationTimeline.install(at: PAGTime(microseconds: 1_000_000))
        let originalIDs = Set(composition.edits.images.keys)
        try await composition.apply(.image(image), forTag: slots[1].tag)
        var second = try await PreparedScene.prepare(composition, reusing: first)
        second.imageAnimationTimeline.install(at: PAGTime(microseconds: 3_000_000))
        for id in composition.edits.images.keys {
            let expected: Int64 = originalIDs.contains(id) ? 3_000_000 : 1_000_000
            #expect(second.imageAnimationTimeline.elapsed(for: id, at: PAGTime(microseconds: 4_000_000)).microseconds == expected)
        }
        try await composition.apply(.hidden, forTag: slots[0].tag)
        var hidden = try await PreparedScene.prepare(composition, reusing: second)
        hidden.imageAnimationTimeline.install(at: PAGTime(microseconds: 4_000_000))
        for id in originalIDs {
            #expect(hidden.imageAnimationTimeline.elapsed(for: id, at: PAGTime(microseconds: 5_000_000)).microseconds == 4_000_000)
        }
        let replacement = try await PAGImage.animated(from: FourSecondImageSource())
        try await composition.apply(.image(replacement), forTag: slots[0].tag)
        var replaced = try await PreparedScene.prepare(composition, reusing: hidden)
        replaced.imageAnimationTimeline.install(at: PAGTime(microseconds: 5_000_000))
        for id in originalIDs {
            #expect(replaced.imageAnimationTimeline.elapsed(for: id, at: PAGTime(microseconds: 5_000_000)) == .zero)
        }
    }

    /// 通过已有语义图构造器建立真实图片层与四秒帧源，不编造 PAG 字节。
    private func scene(playCount: Int? = nil) async throws -> PreparedScene {
        let file = try await ImageTimeFixtures.file(rule: nil, start: 0, duration: 60, offsets: [0], fileDuration: 60)
        let image = try await PAGImage.animated(from: FourSecondImageSource(playCount: playCount))
        var composition = file.composition
        try await composition.apply(.image(image), forTag: #require(file.contentSlots.first?.tag))
        var scene = try await PreparedScene.prepare(composition)
        scene.imageAnimationTimeline.install(at: .zero)
        return scene
    }

    /// 使用生产纯时间状态机，根时长两秒，不依赖墙钟 sleep。
    private func timeline(repeatCount: Int = 0) throws -> PlaybackTimeline {
        var timeline = PlaybackTimeline()
        try timeline.install(duration: PAGTime(microseconds: 2_000_000))
        timeline.setRepeatCount(repeatCount, at: 0)
        timeline.setTarget(.available, at: 0)
        try timeline.play(at: 0)
        return timeline
    }

    /// 根请求时间与动图累计时间分开传入正式帧计划，检查真正选中的像素帧。
    private func pixels(_ scene: PreparedScene, timeline: PlaybackTimeline) async throws -> UInt8 {
        let frame = try await FramePlanner.prepare(scene, at: timeline.position, targetSize: scene.composition.size,
            scale: 1, mode: .none, imageAnimationTime: PAGTime(microseconds: Int64(timeline.imageElapsed)))
        return try #require(frame.images.values.first?.storage.pixels.first)
    }
}

/// 四张一秒完整帧，颜色首字节直接编码帧序号；只负责帧数据，不持有时钟或可变状态。
private struct FourSecondImageSource: PAGAnimatedImageSource {
    /// 不变的四秒时间表，nil 轮数无限循环。
    let info: PAGAnimatedImageInfo

    /// 创建一像素语义帧源，有限轮数交给正式动画采样器解释。
    init(playCount: Int? = nil) throws {
        info = try PAGAnimatedImageInfo(size: PAGSize(width: 1, height: 1),
            frameDurations: Array(repeating: PAGTime(microseconds: 1_000_000), count: 4), playCount: playCount)
    }

    /// 返回完整预乘 RGBA 帧，序号 0...3 分别映射到颜色 1...4。
    func frame(at index: Int) throws -> PAGImageFrame? {
        try PAGImageFrame(width: 1, height: 1, pixels: Data([UInt8(index + 1), 0, 0, 255]))
    }
}
