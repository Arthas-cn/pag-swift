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
    /// 2J的真实无Effects预合成在动态帧借紧致内容附件，逐帧释放后不留GPU预算占用。
    @Test func twoJPreparesPlainMotionBlurFrames() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "2J.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        let root = file.storage.compositions[file.storage.rootIndex]
        var blurred = 0
        for index in 0..<root.durationFrames {
            let frame = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: index, rate: root.frameRate),
                targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
            let batch = try MetalFramePreparation.prepare(frame, width: 256, height: 256,
                resources: resources, disablePictureCache: true)
            blurred += batch.passes.reduce(0) { $0 + $1.draws.filter { $0.motionBlur != nil }.count }
            #expect(batch.passes.last?.attachment == nil)
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
        #expect(blurred > 0)
        print("PAG_2J_BLUR_PREPARED frames=\(root.durationFrames) draws=\(blurred)")
    }

    /// 2J的动态模糊必须在已挂载macOS drawable留下实际有色像素与去滤镜差分。
    @MainActor @Test func twoJPlainBlurChangesMountedDrawablePixels() async throws {
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
            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "2J.pag"))
            let scene = try await PreparedScene.prepare(file.composition)
            let root = file.storage.compositions[file.storage.rootIndex]
            let points = (0..<64).flatMap { row in (0..<64).map { column in
                SIMD2<Int>(2 + column * 4, 2 + row * 4)
            } }
            var difference = 0
            var examined = 0
            for index in 0..<root.durationFrames {
                let frame = try await FramePlanner.prepare(scene,
                    at: SceneValidator.time(frame: index, rate: root.frameRate),
                    targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
                var removedBlur = false
                let plainCommands = frame.plan.commands.map { command -> FrameCommand in
                    guard case .beginGroup(let group) = command,
                          group.layerID?.path.last == 568, group.motionBlur != nil else { return command }
                    removedBlur = true
                    return .beginGroup(FrameGroup(layerID: group.layerID, frame: group.frame,
                        clip: group.clip, opacity: group.opacity, application: group.application,
                        definitionIndex: group.definitionIndex, blendMode: group.blendMode,
                        levelsGreenOnly: group.levelsGreenOnly, motionTile: group.motionTile))
                }
                guard removedBlur else { continue }
                examined += 1
                let plain = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                    targetBounds: frame.plan.targetBounds, commands: plainCommands),
                    images: frame.images, shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
                let blurred = try await owner.pixels(frame, target: target, at: points)
                let baseline = try await owner.pixels(plain, target: target, at: points)
                difference = zip(blurred, baseline).filter { $0.0 != $0.1 }.count
                if difference > 0 {
                    #expect(blurred.contains { $0.w > 0 })
                    print("PAG_2J_MOUNTED_BLUR frame=\(index) differing=\(difference) samples=\(points.count)")
                    break
                }
            }
            #expect(examined > 0)
            #expect(difference > 0)
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// MT2的逐帧图像MotionTile先于动态模糊，生产批次直接以根附件结束且不借整帧纹理。
    @Test func mt2PreparesTiledImageBlurFrames() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "MT2.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        let root = file.storage.compositions[file.storage.rootIndex]
        var blurred = 0
        for index in 0..<root.durationFrames {
            let frame = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: index, rate: root.frameRate),
                targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
            let batch = try MetalFramePreparation.prepare(frame, width: 256, height: 256,
                resources: resources, disablePictureCache: true)
            let rootDraws = batch.passes.last?.draws.filter {
                $0.motionBlur != nil && $0.motionTile != nil
            }.count ?? 0
            let allDraws = batch.passes.reduce(0) { $0 + $1.draws.filter {
                $0.motionBlur != nil && $0.motionTile != nil
            }.count }
            // 图像双效果直接写最终显示附件，不能悄悄退回整帧颜色中转。
            #expect(rootDraws == allDraws)
            blurred += rootDraws
            #expect(batch.passes.last?.attachment == nil)
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
        #expect(blurred > 0)
        print("PAG_MT2_BLUR_PREPARED frames=\(root.durationFrames) draws=\(blurred)")
    }

    /// MT2真实平铺图像在已挂载drawable上有色，且去掉tag63后同一帧像素应改变。
    @MainActor @Test func mt2TiledBlurChangesMountedDrawablePixels() async throws {
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
            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "MT2.pag"))
            let scene = try await PreparedScene.prepare(file.composition)
            let root = file.storage.compositions[file.storage.rootIndex]
            let points = (0..<64).flatMap { row in (0..<64).map { column in
                SIMD2<Int>(2 + column * 4, 2 + row * 4)
            } }
            var difference = 0
            var examined = 0
            for index in 0..<root.durationFrames {
                let frame = try await FramePlanner.prepare(scene,
                    at: SceneValidator.time(frame: index, rate: root.frameRate),
                    targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
                var removedBlur = false
                let plainCommands = frame.plan.commands.map { command -> FrameCommand in
                    guard case .image(let value) = command,
                          value.layerID?.path.last == 1131354215, value.motionBlur != nil else {
                        return command
                    }
                    removedBlur = true
                    return .image(FrameImage(layerID: value.layerID, resourceID: value.resourceID,
                        pixelSize: value.pixelSize, matrix: value.matrix, clip: value.clip,
                        opacity: value.opacity, contentTime: value.contentTime,
                        motionTile: value.motionTile, bulge: value.bulge, cornerPin: value.cornerPin))
                }
                guard removedBlur else { continue }
                examined += 1
                let plain = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                    targetBounds: frame.plan.targetBounds, commands: plainCommands),
                    images: frame.images, shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
                let blurred = try await owner.pixels(frame, target: target, at: points)
                let baseline = try await owner.pixels(plain, target: target, at: points)
                difference = zip(blurred, baseline).filter { $0.0 != $0.1 }.count
                if difference > 0 {
                    #expect(blurred.contains { $0.w > 0 })
                    print("PAG_MT2_MOUNTED_BLUR frame=\(index) differing=\(difference) samples=\(points.count)")
                    break
                }
            }
            #expect(examined > 0)
            #expect(difference > 0)
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

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
