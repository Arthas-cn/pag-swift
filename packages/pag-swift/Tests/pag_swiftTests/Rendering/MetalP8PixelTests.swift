#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// P8动态图、视频和滚动文字共用一个真实窗口drawable，比较实际像素而非只检查计划状态。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalP8PixelTests {
    /// 同一挂载目标上，GIF处置末帧、视频后续帧和滚动字形均产生可见像素变化。
    @MainActor @Test func animatedVideoAndMarqueeChangeDrawablePixels() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 360, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · P8 pixels"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 640))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget(width: 360, height: 640)
        let owner = MetalStrokePixelOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            let mutation = try #require(target.mailbox.beginMutation())
            try await owner.configure(target, mutation: mutation)
            try target.mount(to: #require(view.layer), mutation: mutation)
            #expect(target.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: try DisplayGeometry(size: PAGSize(width: 360, height: 640), scale: 1),
                isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()

            let imageFile = try await ImageTimeFixtures.file(rule: nil, start: 0,
                duration: 300, offsets: [0], fileDuration: 300)
            var animated = imageFile.composition
            let gif = try await PAGImage.load(data: PAGFixtures.data(named: "media/optimized-disposal.gif"))
            try animated.replaceImage(gif, at: 0)
            let gifScene = try await PreparedScene.prepare(animated)
            let mediaPoints = [SIMD2(90, 320), SIMD2(270, 320)]
            let gifStart = try await owner.pixels(frame(gifScene, at: .zero), target: target, at: mediaPoints)
            let gifEnd = try await owner.pixels(frame(gifScene, at: .zero, imageTime: 300_000),
                target: target, at: mediaPoints)
            #expect(gifStart != gifEnd, "局部帧和恢复背景处置必须改变真实drawable")

            var video = imageFile.composition
            let movie = try await PAGImage.loadVideo(from: PAGFixtures.rootURL().appendingPathComponent("game.mp4"))
            try video.replaceImage(movie, at: 0)
            let videoScene = try await PreparedScene.prepare(video)
            let videoPoints = stride(from: 280, through: 360, by: 16).flatMap { y in
                stride(from: 120, through: 240, by: 16).map { x in SIMD2(x, y) }
            }
            let videoStart = try await owner.pixels(frame(videoScene, at: .zero), target: target, at: videoPoints)
            let videoLater = try await owner.pixels(frame(videoScene, at: PAGTime(microseconds: 1_000_000)),
                target: target, at: videoPoints)
            #expect(videoStart != videoLater, "NV12系统输出必须进入同一drawable并随PAG时间改变")

            let textFile = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
            var text = textFile.composition
            var style = try text.text(at: 0)
            style.text = String(repeating: "A", count: 40)
            try text.replaceText(style, at: 0)
            try text.setTextOverflow(.marquee(PAGMarqueeOptions(speed: 200, gap: 20)), at: 0)
            let textScene = try await PreparedScene.prepare(text)
            let textPoints = stride(from: 280, through: 340, by: 8).flatMap { y in
                stride(from: 96, through: 264, by: 8).map { x in SIMD2(x, y) }
            }
            let first = try await frame(textScene, at: .zero, active: 1_000_000, playing: true)
            let textStart = try await owner.pixels(first, target: target, at: textPoints)
            textScene.marqueeClock?.activate(first.marqueeIDs, at: PAGTime(microseconds: 1_000_000))
            let textMoved = try await owner.pixels(frame(textScene, at: .zero,
                active: 1_250_000, playing: true), target: target, at: textPoints)
            #expect(textStart != textMoved, "辅助时间应移动框内真实字形")
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// 根位置、跑马灯激活时间与 GIF 独立进度分别传入正式规划，不能用根 seek 代替动图推进。
    private func frame(_ scene: PreparedScene, at time: PAGTime,
                       active: Int64 = 0, imageTime: Int64 = 0, playing: Bool = false) async throws -> PreparedFrame {
        try await FramePlanner.prepare(scene, at: time,
            targetSize: try PAGSize(width: 360, height: 640), scale: 1, mode: .aspectFit,
            isPlaying: playing, auxiliaryTime: PAGTime(microseconds: active),
            imageAnimationTime: PAGTime(microseconds: imageTime))
    }
}
#endif
