#if os(macOS)
import AppKit
import Metal
import QuartzCore
import Testing
@testable import pag_swift

/// 真实LOGO的整层Angle样式和两层轨道遮罩在生产macOS drawable上的画面验证。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalGradientOverlayFileTests {
    /// LOGO全部300源帧都能准备嵌套局部Metal工作，且每帧借用附件完整归还。
    @Test func allSourceFramesPrepareMetal() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "PAG_LOGO.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let size = try PAGSize(width: 256, height: 256)
        let resources = try MetalResources(device: #require(MTLCreateSystemDefaultDevice()))
        for index in 0..<root.durationFrames {
            let frame = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: index, rate: root.frameRate),
                targetSize: size, scale: 1, mode: .aspectFit)
            let batch = try MetalFramePreparation.prepare(frame, width: 256, height: 256,
                resources: resources, disablePictureCache: true)
            #expect(batch.passes.last?.attachment == nil)
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
    }

    /// 中帧在已挂载drawable应有非透明像素，且移除tag85样式后实际画面发生变化。
    @MainActor @Test func logoStyleChangesMountedDrawablePixels() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 256, height: 256),
            styleMask: [.titled], backing: .buffered, defer: false)
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

            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "PAG_LOGO.pag"))
            let scene = try await PreparedScene.prepare(file.composition)
            let root = try #require(file.storage.compositions.last)
            let frame = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: root.durationFrames / 2, rate: root.frameRate),
                targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
            let plainCommands = frame.plan.commands.filter { command in
                switch command {
                case .beginGradientOverlay, .endGradientOverlay: false
                default: true
                }
            }
            #expect(plainCommands.count == frame.plan.commands.count - 2)
            let plain = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                targetBounds: frame.plan.targetBounds, commands: plainCommands),
                images: frame.images, shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
            let changedCommands = frame.plan.commands.map { command -> FrameCommand in
                guard case .beginGradientOverlay(let overlay) = command else { return command }
                return .beginGradientOverlay(FrameGradientOverlay(layerID: overlay.layerID,
                    angle: 200, opacity: overlay.opacity))
            }
            let changedAngle = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                targetBounds: frame.plan.targetBounds, commands: changedCommands),
                images: frame.images, shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
            let points = (0..<64).flatMap { row in (0..<64).map { column in
                SIMD2<Int>(2 + column * 4, 2 + row * 4)
            } }
            let styled = try await owner.pixels(frame, target: target, at: points)
            let unstyled = try await owner.pixels(plain, target: target, at: points)
            let rotated = try await owner.pixels(changedAngle, target: target, at: points)
            #expect(styled.contains { $0.w > 0 })
            let differences = zip(styled, unstyled).filter { $0.0 != $0.1 }.count
            print("PAG_LOGO_GRADIENT_PIXELS frame=\(root.durationFrames / 2) differing=\(differences)")
            #expect(differences > 0)
            let angleDifferences = zip(styled, rotated).filter { $0.0 != $0.1 }.count
            print("PAG_LOGO_GRADIENT_ANGLE_PIXELS differing=\(angleDifferences)")
            #expect(angleDifferences > 0)
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
