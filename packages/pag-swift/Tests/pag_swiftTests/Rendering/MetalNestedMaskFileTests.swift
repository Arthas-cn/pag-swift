#if os(macOS)
import AppKit
import Metal
import QuartzCore
import Testing
@testable import pag_swift

/// 真实双层普通路径蒙版在同一图像draw与根drawable上的交集画面。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalNestedMaskFileTests {
    /// travel全部源帧都应能在固定256目标准备Metal，并在每帧归还有界轨道遮罩附件。
    @Test func travelAllSourceFramesPrepareMetal() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "travel.pag"))
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

    /// shanzi_video首中末帧的深度2作用域须完整准备，两层输入的附件归还不泄漏。
    @Test func realFilePreparesTwoPathScopes() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "shanzi_video.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        for index in Set([Int64(0), root.durationFrames / 2, root.durationFrames - 1]).sorted() {
            let frame = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: index, rate: root.frameRate),
                targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
            let batch = try MetalFramePreparation.prepare(frame, width: 256, height: 256,
                resources: resources, disablePictureCache: true)
            #expect(batch.passes.last?.attachment == nil)
            #expect(batch.passes.last?.draws.contains(where: { $0.parentMask != nil }) == true)
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
    }

    /// 双mask作用域若改为两张Image，须拒绝未经证明的多draw合成顺序并归还附件。
    @Test func rejectsMultipleImagesWithinInnerMask() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "shanzi_video.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let frame = try await FramePlanner.prepare(scene,
            at: SceneValidator.time(frame: root.durationFrames / 2, rate: root.frameRate),
            targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
        var commands: [FrameCommand] = []
        var depth = 0
        var duplicated = false
        for command in frame.plan.commands {
            if case .beginMask = command { depth += 1 }
            commands.append(command)
            if depth == 2, case .image = command, !duplicated {
                commands.append(command)
                duplicated = true
            }
            if case .endMask = command { depth -= 1 }
        }
        #expect(duplicated && depth == 0)
        let doubled = PreparedFrame(plan: FramePlan(time: frame.plan.time,
            targetBounds: frame.plan.targetBounds, commands: commands),
            images: frame.images, shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        #expect(throws: PAGError.unsupportedFeature("nestedMaskPaths")) {
            try MetalFramePreparation.prepare(doubled, width: 256, height: 256,
                resources: resources, disablePictureCache: true)
        }
        #expect(resources.groups.activeBytes == 0)
    }

    /// 真实首中末帧移除内层mask后，挂载drawable须出现非透明内容及效果差分。
    @MainActor @Test func realFileChangesMountedDrawablePixels() async throws {
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

            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "shanzi_video.pag"))
            let scene = try await PreparedScene.prepare(file.composition)
            let root = try #require(file.storage.compositions.last)
            let points = (0..<64).flatMap { row in (0..<64).map { column in
                SIMD2<Int>(2 + column * 4, 2 + row * 4)
            } }
            var differingSamples = 0
            for index in Set([Int64(0), root.durationFrames / 2, root.durationFrames - 1]).sorted() {
                let frame = try await FramePlanner.prepare(scene,
                    at: SceneValidator.time(frame: index, rate: root.frameRate),
                    targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
                var depth = 0
                var removed = 0
                var plainCommands: [FrameCommand] = []
                for command in frame.plan.commands {
                    switch command {
                    case .beginMask:
                        depth += 1
                        if depth == 2 { removed += 1; continue }
                    case .endMask:
                        if depth == 2 { depth -= 1; continue }
                        depth -= 1
                    default: break
                    }
                    plainCommands.append(command)
                }
                #expect(depth == 0 && removed > 0)
                let plain = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                    targetBounds: frame.plan.targetBounds, commands: plainCommands),
                    images: frame.images, shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
                let clipped = try await owner.pixels(frame, target: target, at: points)
                let unclipped = try await owner.pixels(plain, target: target, at: points)
                #expect(clipped.contains { $0.w > 0 })
                let differences = zip(clipped, unclipped).filter { $0.0 != $0.1 }.count
                differingSamples += differences
                print("PAG_DOUBLE_MASK_PIXELS frame=\(index) differing=\(differences)")
            }
            #expect(differingSamples > 0)
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// travel中末帧的三组Difference蒙版应在已挂载的macOS drawable产生真实非透明差分。
    @MainActor @Test func travelDifferenceMasksChangeMountedDrawablePixels() async throws {
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

            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "travel.pag"))
            let scene = try await PreparedScene.prepare(file.composition)
            let root = try #require(file.storage.compositions.last)
            let points = (0..<64).flatMap { row in (0..<64).map { column in
                SIMD2<Int>(2 + column * 4, 2 + row * 4)
            } }
            var differingSamples = 0
            for index in Set([root.durationFrames / 2, root.durationFrames - 1]).sorted() {
                let frame = try await FramePlanner.prepare(scene,
                    at: SceneValidator.time(frame: index, rate: root.frameRate),
                    targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
                var removed = 0
                var insideExpression = false
                var plainCommands: [FrameCommand] = []
                for command in frame.plan.commands {
                    switch command {
                    case .beginMask(let mask):
                        if case .expression = mask.source {
                            #expect(!insideExpression)
                            insideExpression = true
                            removed += 1
                            continue
                        }
                    case .endMask where insideExpression:
                        insideExpression = false
                        continue
                    default: break
                    }
                    plainCommands.append(command)
                }
                #expect(removed == 3 && !insideExpression)
                let plain = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                    targetBounds: frame.plan.targetBounds, commands: plainCommands),
                    images: frame.images, shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
                let masked = try await owner.pixels(frame, target: target, at: points)
                let unmasked = try await owner.pixels(plain, target: target, at: points)
                #expect(masked.contains { $0.w > 0 })
                let differences = zip(masked, unmasked).filter { $0.0 != $0.1 }.count
                differingSamples += differences
                print("PAG_TRAVEL_MASK_PIXELS frame=\(index) differing=\(differences)")
            }
            #expect(differingSamples > 0)
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
