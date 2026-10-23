#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 新槽位 alpha 在真实 drawable 的图像片元生效，包含动图换帧、静态首帧及自定义路径方向。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalSlotMaskPixelTests {
    /// 同一窗口中检查圆外透明、圆内动图换色、静态保持首帧，并确认路径左上坐标不翻转。
    @MainActor @Test func slotMaskMultipliesEveryFrameWithoutCroppingTheSource() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 100, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "pag-swift · slot alpha"
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget(width: 100, height: 80)
        let owner = MetalStrokePixelOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            let mutation = try #require(target.mailbox.beginMutation())
            try await owner.configure(target, mutation: mutation)
            try target.mount(to: #require(view.layer), mutation: mutation)
            #expect(target.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: try DisplayGeometry(size: PAGSize(width: 100, height: 80), scale: 1),
                isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            try await verifyFrames(owner: owner, target: target)
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// 正式 tag 编辑、帧规划和 Metal 图像管线共用同一素材，断言的是 GPU 输出 RGBA。
    private func verifyFrames(owner: MetalStrokePixelOwner, target: MetalStrokePixelTarget) async throws {
        let file = try await ImageTimeFixtures.file(rule: nil, start: 0, duration: 60, offsets: [0], fileDuration: 60)
        let tag = try #require(file.contentSlots.first?.tag)
        let animated = try await PAGImage.animated(from: MaskColorFrames())
        var composition = file.composition
        try await composition.apply(.image(animated, options: .init(scaleMode: .stretch, mask: .circle)), forTag: tag)
        let scene = try await PreparedScene.prepare(composition)
        let points = [SIMD2(2, 2), SIMD2(50, 40), SIMD2(97, 77)]
        let first = try await owner.pixels(frame(scene, at: 0), target: target, at: points)
        let second = try await owner.pixels(frame(scene, at: 100_000), target: target, at: points)
        #expect(first == [SIMD4(0, 0, 0, 0), SIMD4(255, 0, 0, 255), SIMD4(0, 0, 0, 0)])
        #expect(second == [SIMD4(0, 0, 0, 0), SIMD4(0, 0, 255, 255), SIMD4(0, 0, 0, 0)])
        #expect(await owner.lastDrawCount == 1, "槽位遮罩和动态图像必须复用同一次 draw")
        // 再建空媒体缓存，走生产非等待采样；等已存在的预取完成后检查真实 GPU 输出。
        let live = try await PreparedScene.prepare(composition)
        #expect(try await owner.pixels(frame(live, at: 0, live: true), target: target, at: points) == first)
        await live.animatedImages?.waitForCurrentWork()
        #expect(try await owner.pixels(frame(live, at: 100_000, live: true), target: target, at: points) == second)
        try await composition.apply(.image(animated, options: .init(playbackMode: .still,
            scaleMode: .stretch, mask: .circle)), forTag: tag)
        let still = try await PreparedScene.prepare(composition)
        #expect(try await owner.pixels(frame(still, at: 100_000), target: target, at: points) == first)
        let triangle = CGMutablePath()
        triangle.move(to: .zero)
        triangle.addLine(to: CGPoint(x: 100, y: 0))
        triangle.addLine(to: CGPoint(x: 0, y: 80))
        triangle.closeSubpath()
        let custom = try PAGMaskPath(triangle, coordinateSize: PAGSize(width: 100, height: 80))
        try await composition.apply(.image(animated, options: .init(scaleMode: .stretch, mask: .path(custom))), forTag: tag)
        let pathScene = try await PreparedScene.prepare(composition)
        let pathPixels = try await owner.pixels(frame(pathScene, at: 0), target: target,
                                                at: [SIMD2(10, 10), SIMD2(90, 70)])
        #expect(pathPixels == [SIMD4(255, 0, 0, 255), SIMD4(0, 0, 0, 0)])
        let alpha = try await PAGImage.make(from: PAGImageFrame(width: 1, height: 1, pixels: Data([0, 128, 0, 128])))
        try await composition.apply(.image(animated, options: .init(scaleMode: .stretch,
            mask: .alphaImage(alpha, scaleMode: .stretch))), forTag: tag)
        let alphaScene = try await PreparedScene.prepare(composition)
        let alphaPixels = try await owner.pixels(frame(alphaScene, at: 0), target: target, at: [SIMD2(50, 40)])
        #expect(abs(Int(alphaPixels[0].x) - 128) <= 1 && alphaPixels[0].y == 0)
        #expect(abs(Int(alphaPixels[0].w) - 128) <= 1, "遮罩只取 alpha，绿色不得混入红色头像")
    }

    /// 根 PAG 固定零帧，只有素材时钟变化，排除依赖根进度的假动态效果。
    private func frame(_ scene: PreparedScene, at imageTime: Int64, live: Bool = false) async throws -> PreparedFrame {
        try await FramePlanner.prepare(scene, at: .zero, targetSize: PAGSize(width: 100, height: 80),
            scale: 1, mode: .aspectFit, isPlaying: live, imageAnimationTime: PAGTime(microseconds: imageTime),
            waitsForAnimatedImages: !live)
    }
}

/// 两帧全不透明的语义素材，便于将遮罩 alpha 与输入图像本身的透明度区分。
private struct MaskColorFrames: PAGAnimatedImageSource {
    /// 两帧各 100 毫秒，独立无限循环。
    let info: PAGAnimatedImageInfo
    /// 验证两像素画布与逐帧时长，不保存可变解码器。
    init() throws {
        info = try PAGAnimatedImageInfo(size: PAGSize(width: 2, height: 1),
            frameDurations: [PAGTime(microseconds: 100_000), PAGTime(microseconds: 100_000)])
    }
    /// 第一帧全红，第二帧全蓝，完整画布均已预乘。
    func frame(at index: Int) throws -> PAGImageFrame? {
        let color: [UInt8] = index == 0 ? [255, 0, 0, 255] : [0, 0, 255, 255]
        return try PAGImageFrame(width: 2, height: 1, pixels: Data(color + color))
    }
}
#endif
