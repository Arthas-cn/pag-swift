#if os(macOS)
import AppKit
import Metal
import QuartzCore
import Testing
@testable import pag_swift

/// 真实Screen预合成tag63进入逐帧计划；有色内容的片元取样另由挂载目标专项验证。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalMotionBlurFileTests {
    /// clip2整个可见区间都能准备，变化帧进入计划；无子内容时不伪称执行了片元。
    @Test func clip2PreparesVisibleMotionBlurFrames() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "nodegroup_clip2.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        var changedPlans = 0
        var sampledDraws = 0
        let source = file.storage.compositions[file.storage.rootIndex]
        let layer = try #require(source.layers.first { $0.id == 265 })
        for frameNumber in layer.startFrame..<(layer.startFrame + layer.durationFrames) {
            let time = try SceneValidator.time(frame: frameNumber, rate: source.frameRate)
            let frame = try await FramePlanner.prepare(scene,
                at: time, targetSize: try PAGSize(width: 256, height: 256),
                scale: 1, mode: .aspectFit)
            if frame.plan.commands.contains(where: {
                if case .beginGroup(let group) = $0 { return group.motionBlur != nil }
                return false
            }) { changedPlans += 1 }
            let batch = try MetalFramePreparation.prepare(frame, width: 256, height: 256,
                resources: resources, disablePictureCache: true)
            #expect(batch.passes.last?.attachment == nil)
            let draws = batch.passes.reduce(0) { $0 + $1.draws.filter { $0.motionBlur != nil }.count }
            sampledDraws += draws
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
        #expect(changedPlans > 0)
        #expect(sampledDraws > 0)
    }

    /// 根合成第49帧实际启用tag63，在已挂载drawable与去效果基线出现像素差分。
    @MainActor @Test func clip2MotionBlurChangesMountedDrawablePixels() async throws {
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
            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "nodegroup_clip2.pag"))
            let scene = try await PreparedScene.prepare(file.composition)
            let source = file.storage.compositions[file.storage.rootIndex]
            let layer = try #require(source.layers.first { $0.id == 265 })
            let points = (0..<64).flatMap { row in (0..<64).map { column in
                SIMD2<Int>(2 + column * 4, 2 + row * 4)
            } }
            let time = try SceneValidator.time(frame: layer.startFrame + 2, rate: source.frameRate)
            let frame = try await FramePlanner.prepare(scene, at: time,
                targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
            #expect(frame.plan.commands.contains {
                if case .beginGroup(let group) = $0 { return group.motionBlur != nil }
                return false
            })
            let plainCommands = frame.plan.commands.map { command -> FrameCommand in
                guard case .beginGroup(let group) = command, group.motionBlur != nil else { return command }
                return .beginGroup(FrameGroup(layerID: group.layerID, frame: group.frame,
                    clip: group.clip, opacity: group.opacity, application: group.application,
                    definitionIndex: group.definitionIndex, blendMode: group.blendMode,
                    levelsGreenOnly: group.levelsGreenOnly, motionTile: group.motionTile))
            }
            let plain = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                targetBounds: frame.plan.targetBounds, commands: plainCommands),
                images: frame.images, shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
            let blurredPixels = try await owner.pixels(frame, target: target, at: points)
            let plainPixels = try await owner.pixels(plain, target: target, at: points)
            let differing = zip(blurredPixels, plainPixels).filter { $0.0 != $0.1 }.count
            #expect(blurredPixels.contains { $0.w > 0 })
            #expect(differing > 0)
            print("PAG_CLIP2_MOUNTED_BLUR differing=\(differing) samples=\(points.count)")
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
