#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 在真实 drawable 上对照原框与放宽垂直裁剪的像素，防止仅几何断言通过但仍然切字。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct MetalTextOverflowPixelTests {
    /// 截断和跑马灯的上下轮廓都应完整：放宽槽位垂直裁剪后不应再多出任何像素。
    @MainActor @Test func slotClipDoesNotRemoveTopOrBottomInk() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 170, y: 170, width: 376, height: 64),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · text overflow pixels"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 376, height: 64))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget(width: 376, height: 64)
        let owner = MetalStrokePixelOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            let mutation = try #require(target.mailbox.beginMutation())
            try await owner.configure(target, mutation: mutation)
            try target.mount(to: #require(view.layer), mutation: mutation)
            #expect(target.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: try DisplayGeometry(size: PAGSize(width: 376, height: 64), scale: 1),
                isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
            let points = stride(from: 0, to: 64, by: 2).flatMap { y in
                stride(from: 1, to: 376, by: 3).map { SIMD2($0, y) }
            }
            for layout in [DynamicTextLayout.truncate, .marquee(try PAGMarqueeOptions())] {
                var composition = file.composition
                try await composition.apply(.text(String(repeating: "PAG Swift 动态 Ágjpqy ", count: 8), layout: layout),
                                            forTag: "text:0")
                let scene = try await PreparedScene.prepare(composition)
                let frame = try await FramePlanner.prepare(scene, at: .zero,
                    targetSize: PAGSize(width: 376, height: 64), scale: 1, mode: .aspectFit)
                let clipped = try await owner.pixels(frame, target: target, at: points)
                let commands = try frame.plan.commands.map { command -> FrameCommand in
                    guard case .beginGroup(let group) = command, group.layerID != nil else { return command }
                    // 只放宽文字槽的上下边界，水平滚动窗口与根合成裁剪保持一致。
                    let clip = FrameClip(size: try PAGSize(width: group.clip.size.width,
                                                          height: group.clip.size.height + 2000),
                        matrix: try SceneAffine.translation(x: 0, y: -1000).following(group.clip.matrix))
                    return .beginGroup(FrameGroup(layerID: group.layerID, frame: group.frame, clip: clip, opacity: 1))
                }
                let reference = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                    targetBounds: frame.plan.targetBounds, commands: commands),
                    images: frame.images, shapes: frame.shapes, texts: frame.texts)
                let unclipped = try await owner.pixels(reference, target: target, at: points)
                #expect(clipped.contains { $0.w > 0 }, "必须实际画出文字，不能以空白帧通过")
                #expect(clipped == unclipped, "原框裁剪不应削掉任何顶部、底部或描边像素")
            }
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }
}
#endif
