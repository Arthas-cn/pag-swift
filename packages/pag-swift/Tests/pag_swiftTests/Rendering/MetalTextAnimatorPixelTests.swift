#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 已挂载macOS drawable上的tag70真实文字像素，而非仅验证加载状态或GPU编码。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(2)))
struct MetalTextAnimatorPixelTests {
    /// 八份已越过其它P7门禁的文件须有字形像素，动态选择器须改变实际画面。
    @MainActor @Test func realAnimatorsProduceMountedDrawablePixels() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 256, height: 256),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · Text Animator"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 256, height: 256))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget(width: 256, height: 256)
        let owner = MetalStrokePixelOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            let mutation = try #require(target.mailbox.beginMutation())
            try await owner.configure(target, mutation: mutation)
            try target.mount(to: #require(view.layer), mutation: mutation)
            #expect(target.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: try DisplayGeometry(size: PAGSize(width: 256, height: 256), scale: 1),
                isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            let points = (0..<64).flatMap { row in (0..<64).map { column in
                SIMD2<Int>(2 + column * 4, 2 + row * 4)
            } }
            let names = ["RangeSelectorTriangleEaseHighAndLow.pag", "TextAnimatorMode.pag",
                "TextAnimatorSmooth.pag", "TextPositionAnimator.pag", "TrackingAnimatorVertical.pag",
                "TextAnimators.pag", "TrackingAnimator.pag", "TextAnimatorX7.pag"]
            var samples: [String: [[SIMD4<UInt8>]]] = [:]
            for name in names {
                let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
                let scene = try await PreparedScene.prepare(file.composition)
                let root = try #require(file.storage.compositions.last)
                var frames: [[SIMD4<UInt8>]] = []
                for index in Set([Int64(0), root.durationFrames / 2, root.durationFrames - 1]).sorted() {
                    let frame = try await FramePlanner.prepare(scene,
                        at: SceneValidator.time(frame: index, rate: root.frameRate),
                        targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .stretch)
                    let pixels = try await owner.pixels(frame, target: target, at: points)
                    #expect(pixels.contains(where: { $0.w > 0 }), "file=\(name) frame=\(index)")
                    frames.append(pixels)
                }
                samples[name] = frames
            }
            let mode = try #require(samples["TextAnimatorMode.pag"])
            let smooth = try #require(samples["TextAnimatorSmooth.pag"])
            #expect(mode[0] != mode[1] || mode[1] != mode[2])
            #expect(smooth[0] != smooth[1] || smooth[1] != smooth[2])
            await target.close()
            window.close()
        } catch {
            await target.close()
            window.close()
            throw error
        }
    }
}
#endif
