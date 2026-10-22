#if os(macOS)
import AppKit
import Metal
import QuartzCore
import Testing
@testable import pag_swift

/// clip1真实层115从正式解码、逐帧求值到有界Metal批次的接线与借用归还。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(2)))
struct MetalTileGlowBulgeFrameTests {
    /// 首个可见帧必须生成MotionTile→Glow→Bulge工作并在释放批次后归还全部局部附件。
    @Test func realClip1FrameBuildsBoundedEffectChain() async throws {
        let file = try await PAGLoader().load(data: try PAGFixtures.data(named: "nodegroup_clip1.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let time = try SceneValidator.time(frame: 96, rate: file.composition.frameRate)
        let frame = try await FramePlanner.prepare(scene, at: time,
            targetSize: file.composition.size, scale: 1, mode: .none)
        let group = try #require(frame.plan.commands.compactMap { command -> FrameGroup? in
            if case .beginGroup(let value) = command, value.motionTile != nil,
               value.glow != nil { return value }
            return nil
        }.first)
        #expect(group.tileGlowBulge != nil)
        #expect(group.motionBlur == nil)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        let batch = try MetalFramePreparation.prepare(frame, width: 720, height: 1280,
            resources: resources)
        #expect(batch.mappedTileGlowWorks.count == 1)
        #expect(batch.passes.last?.attachment == nil)
        #expect(batch.passes.last?.draws.contains { $0.tileGlowBulge != nil } == true)
        batch.releaseTransients()
        #expect(resources.groups.activeBytes == 0)
    }

    /// 层115从绝对帧96起的48帧都须准备同一有界工作图，零height帧跳过Bulge且逐帧归还借用。
    @Test func realClip1AllEffectFramesStayWithinBudget() async throws {
        let file = try await PAGLoader().load(data: try PAGFixtures.data(named: "nodegroup_clip1.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        var active = 0
        for sourceFrame in 96..<144 {
            let time = try SceneValidator.time(frame: Int64(sourceFrame),
                rate: file.composition.frameRate)
            let frame = try await FramePlanner.prepare(scene, at: time,
                targetSize: file.composition.size, scale: 1, mode: .none)
            let group = try #require(frame.plan.commands.compactMap { command -> FrameGroup? in
                if case .beginGroup(let value) = command, value.motionTile != nil,
                   value.glow != nil { return value }
                return nil
            }.first)
            if group.tileGlowBulge != nil { active += 1 }
            #expect(group.motionBlur == nil)
            let batch = try MetalFramePreparation.prepare(frame, width: 720, height: 1280,
                resources: resources)
            #expect(batch.mappedTileGlowWorks.count == 1)
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
        #expect(active == 20)
    }

    /// Demo 220点高宿主令三段效果落在分数像素原点；48帧都须继续准备并归还局部附件。
    @Test func realClip1SmallHostKeepsFractionalOriginRenderable() async throws {
        let file = try await PAGLoader().load(data: try PAGFixtures.data(named: "nodegroup_clip1.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        let target = try PAGSize(width: 688, height: 220)
        let visible = try RenderBounds(left: 0, top: 0, right: 1_376, bottom: 440)
        var fractional = 0
        for sourceFrame in 96..<144 {
            let time = try SceneValidator.time(frame: Int64(sourceFrame),
                rate: file.composition.frameRate)
            let frame = try await FramePlanner.prepare(scene, at: time,
                targetSize: target, scale: 2, mode: .aspectFit)
            let group = try #require(frame.plan.commands.compactMap { command -> FrameGroup? in
                if case .beginGroup(let value) = command, value.motionTile != nil,
                   value.glow != nil { return value }
                return nil
            }.first)
            let tile = try #require(group.motionTile)
            let glow = try #require(group.glow)
            let layout = try #require(try TileGlowBulgeLayout(clip: group.clip,
                tile: tile, glow: glow,
                bulge: group.tileGlowBulge, visible: visible))
            if layout.tileBounds.left.rounded() != layout.tileBounds.left ||
               layout.tileBounds.top.rounded() != layout.tileBounds.top { fractional += 1 }
            let batch = try MetalFramePreparation.prepare(frame, width: 1_376, height: 440,
                resources: resources)
            #expect(batch.mappedTileGlowWorks.count == 1)
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
        #expect(fractional > 0)
    }

    /// 真实层115在挂载窗口drawable上的像素应区别于无三段效果基线，并由同一根pass绘制。
    @MainActor @Test func realClip1EffectsReachMountedDrawable() async throws {
        let file = try await PAGLoader().load(data: try PAGFixtures.data(named: "nodegroup_clip1.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let time = try SceneValidator.time(frame: 96, rate: file.composition.frameRate)
        let frame = try await FramePlanner.prepare(scene, at: time,
            targetSize: try PAGSize(width: 360, height: 640), scale: 2, mode: .aspectFit)
        let commands = frame.plan.commands.map { command -> FrameCommand in
            guard case .beginGroup(let value) = command, value.motionTile != nil,
                  value.glow != nil else { return command }
            // 基线只移除本层三个效果；其余真实图层、层时间和资源输入完全相同。
            return .beginGroup(FrameGroup(layerID: value.layerID, frame: value.frame,
                clip: value.clip, opacity: value.opacity, application: value.application,
                definitionIndex: value.definitionIndex, blendMode: value.blendMode))
        }
        let baseline = PreparedFrame(plan: FramePlan(time: frame.plan.time,
            targetBounds: frame.plan.targetBounds, commands: commands),
            images: frame.images, shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
        let noBulgeCommands = frame.plan.commands.map { command -> FrameCommand in
            guard case .beginGroup(let value) = command, value.motionTile != nil,
                  value.glow != nil else { return command }
            return .beginGroup(FrameGroup(layerID: value.layerID, frame: value.frame,
                clip: value.clip, opacity: value.opacity, application: value.application,
                definitionIndex: value.definitionIndex, blendMode: value.blendMode,
                motionTile: value.motionTile, glow: value.glow))
        }
        let noBulge = PreparedFrame(plan: FramePlan(time: frame.plan.time,
            targetBounds: frame.plan.targetBounds, commands: noBulgeCommands),
            images: frame.images, shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 360, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 640))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget(width: 360, height: 640, scale: 2)
        let owner = MetalStrokePixelOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            let mutation = try #require(target.mailbox.beginMutation())
            try await owner.configure(target, mutation: mutation)
            try target.mount(to: #require(view.layer), mutation: mutation)
            #expect(target.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: try DisplayGeometry(size: PAGSize(width: 360, height: 640), scale: 2),
                isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            var points: [SIMD2<Int>] = []
            for y in stride(from: 16, to: 1280, by: 32) {
                for x in stride(from: 16, to: 720, by: 32) { points.append(SIMD2(x, y)) }
            }
            let actual = try await owner.pixels(frame, target: target, at: points)
            let plain = try await owner.pixels(baseline, target: target, at: points)
            let tileGlowOnly = try await owner.pixels(noBulge, target: target, at: points)
            let changed = zip(actual, plain).filter { $0 != $1 }.count
            let bulgeChanged = zip(actual, tileGlowOnly).filter { $0 != $1 }.count
            #expect(changed > 0)
            #expect(bulgeChanged > 0)
            let colored = actual.filter { $0.w > 0 && ($0.x > 0 || $0.y > 0 || $0.z > 0) }.count
            #expect(colored > 0)
            print("PAG_CLIP1_TILE_GLOW_BULGE_PIXELS changed=\(changed) bulgeChanged=\(bulgeChanged) colored=\(colored) sampled=\(points.count) center=\(actual[points.count / 2]) baselineCenter=\(plain[points.count / 2])")
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
