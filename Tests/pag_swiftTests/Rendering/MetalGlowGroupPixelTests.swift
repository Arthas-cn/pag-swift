#if os(macOS)
import AppKit
import Metal
import QuartzCore
import Testing
@testable import pag_swift

/// 单Glow预合成在真实挂载目标的局部pass顺序和可见像素；不冒充clip1整文件验收。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalGlowGroupPixelTests {
    /// Clamp小模糊与真实层Decal最大模糊均按Glow→FastBlur进入工作图，并归还所有附件。
    @Test(arguments: [(4.0, true), (68.0, false)])
    func sourceGlowFastBlurFlowsThroughFramePlanner(_ blurriness: Double,
                                                    _ repeatEdgePixels: Bool) async throws {
        let size = try PAGSize(width: 100, height: 100)
        let red = SceneFixtures.layer(1, transform: SourceTransformProperties(constant:
            SourceTransform(anchor: .zero, position: ScenePoint(x: 10, y: 20),
                scale: .one, rotation: 0, opacity: 255)),
            content: .solid(size: try PAGSize(width: 10, height: 10),
                color: SceneColor(red: 255, green: 0, blue: 0)))
        let child = try SceneFixtures.composition(1, layers: [red])
        let glow = SourceGlow(threshold: SourceProperty(constant: 0.5),
            radius: SourceProperty(constant: 0), intensity: SourceProperty(constant: 1))
        let blur = SourceFastBlur(blurriness: SourceProperty(constant: blurriness),
            direction: SourceProperty(constant: 0),
            repeatEdgePixels: SourceProperty(constant: repeatEdgePixels))
        let parent = SourceLayer(id: 3, name: "glow-fastblur", parentID: nil,
            startFrame: 0, durationFrames: 30, isActive: true,
            transform: SourceTransformProperties(constant: SceneFixtures.transform),
            content: .precomposition(id: 1, startFrame: 0), glow: glow, fastBlur: blur)
        let root = try SceneFixtures.composition(2, layers: [parent])
        let file = try SceneFixtures.build([child, root])
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero,
            targetSize: size, scale: 1, mode: .none)
        let group = try #require(frame.plan.commands.compactMap { command -> FrameGroup? in
            if case .beginGroup(let value) = command, value.fastBlur != nil { return value }
            return nil
        }.first)
        #expect(group.glow != nil)
        #expect(group.fastBlur?.blurriness == blurriness)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        let batch = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
            resources: resources)
        #expect(batch.glowWorks.count == 1)
        #expect(batch.fastBlurWorks.count == 1)
        #expect(batch.loans.count == 8)
        #expect(batch.passes.last?.attachment == nil)
        batch.releaseTransients()
        #expect(resources.groups.activeBytes == 0)
        if !repeatEdgePixels {
            // Decal大halo在部分附件借出后超单帧预算，失败路径也须归还先前借用。
            #expect(throws: PAGError.self) {
                try MetalFramePreparation.prepare(frame, width: 100, height: 100,
                    resources: resources, maximumBytes: 50_000)
            }
            #expect(resources.groups.activeBytes == 0)
        }
    }

    /// 源场景预合成的Glow只附于整组FramePlan，单帧Metal准备借三张局部附件后全部归还。
    @Test func sourceGlowFlowsThroughFramePlanner() async throws {
        let size = try PAGSize(width: 100, height: 100)
        let red = SceneFixtures.layer(1, transform: SourceTransformProperties(constant:
            SourceTransform(anchor: .zero, position: ScenePoint(x: 10, y: 20),
                scale: .one, rotation: 0, opacity: 255)),
            content: .solid(size: try PAGSize(width: 10, height: 10),
                color: SceneColor(red: 255, green: 0, blue: 0)))
        let green = SceneFixtures.layer(2, transform: SourceTransformProperties(constant:
            SourceTransform(anchor: .zero, position: ScenePoint(x: 30, y: 20),
                scale: .one, rotation: 0, opacity: 255)),
            content: .solid(size: try PAGSize(width: 10, height: 10),
                color: SceneColor(red: 0, green: 255, blue: 0)))
        let child = try SceneFixtures.composition(1, layers: [red, green])
        let glow = SourceGlow(threshold: SourceProperty(constant: 0.5),
            radius: SourceProperty(constant: 0), intensity: SourceProperty(constant: 1))
        let parent = SourceLayer(id: 3, name: "glow", parentID: nil,
            startFrame: 0, durationFrames: 30, isActive: true,
            transform: SourceTransformProperties(constant: SceneFixtures.transform),
            content: .precomposition(id: 1, startFrame: 0), glow: glow)
        let root = try SceneFixtures.composition(2, layers: [parent])
        let file = try SceneFixtures.build([child, root])
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero,
            targetSize: size, scale: 1, mode: .none)
        let group = try #require(frame.plan.commands.compactMap { command -> FrameGroup? in
            if case .beginGroup(let value) = command, value.glow != nil { return value }
            return nil
        }.first)
        #expect(group.application == .composite)
        #expect(group.glow?.threshold == 0.5)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        let batch = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
            resources: resources)
        #expect(batch.glowWorks.count == 1)
        #expect(batch.loans.count == 3)
        batch.releaseTransients()
        #expect(resources.groups.activeBytes == 0)
    }

    /// 两块颜色中间的透明间隙应由Glow模糊结果产生颜色，根颜色pass仍直接写drawable。
    @MainActor @Test func glowMergesAfterContentOnMountedDrawable() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget(width: 100, height: 100)
        let owner = MetalStrokePixelOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            let mutation = try #require(target.mailbox.beginMutation())
            try await owner.configure(target, mutation: mutation)
            try target.mount(to: #require(view.layer), mutation: mutation)
            #expect(target.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: try DisplayGeometry(size: PAGSize(width: 100, height: 100), scale: 1),
                isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()

            let layer = try MetalGroupFixtures.layer
            let clip = FrameClip(size: try PAGSize(width: 100, height: 100), matrix: .identity)
            let glow = SampledGlow(threshold: 0.5, radius: 0, intensity: 1)
            let commands: [FrameCommand] = [
                .solid(FrameSolid(layerID: layer, size: clip.size,
                    color: SceneColor(red: 0, green: 0, blue: 255), matrix: .identity, opacity: 1)),
                .beginGroup(FrameGroup(layerID: layer, frame: 0, clip: clip, opacity: 1,
                    application: .composite, glow: glow)),
                .solid(FrameSolid(layerID: layer, size: try PAGSize(width: 10, height: 10),
                    color: SceneColor(red: 255, green: 0, blue: 0),
                    matrix: try .translation(x: 10, y: 20), opacity: 1)),
                .solid(FrameSolid(layerID: layer, size: try PAGSize(width: 10, height: 10),
                    color: SceneColor(red: 0, green: 255, blue: 0),
                    matrix: try .translation(x: 30, y: 20), opacity: 1)),
                .endGroup
            ]
            let frame = MetalGroupFixtures.frame(commands)
            let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
            let batch = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
                resources: resources)
            #expect(batch.passes.count == 2)
            #expect(batch.loans.count == 3)
            #expect(batch.glowWorks[0] != nil)
            #expect(batch.passes.last?.attachment == nil)
            #expect(batch.passes.last?.draws.last?.glow != nil)
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
            let points = [SIMD2(15, 25), SIMD2(20, 25), SIMD2(21, 25),
                          SIMD2(25, 25), SIMD2(35, 25), SIMD2(5, 5)]
            let actual = try await owner.pixels(frame, target: target, at: points)
            var plain = commands
            plain[1] = .beginGroup(FrameGroup(layerID: layer, frame: 0, clip: clip,
                opacity: 1, application: .composite))
            let baseline = try await owner.pixels(MetalGroupFixtures.frame(plain),
                target: target, at: points)
            #expect(actual[0] == baseline[0])
            #expect(actual[1].x > baseline[1].x || actual[2].x > baseline[2].x)
            #expect(actual[3] == baseline[3])
            #expect(actual[5] == baseline[5])
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// 真实挂载drawable上的组外红色halo来自Glow后的FastBlur，基线Glow单独不能覆盖该像素。
    @MainActor @Test func glowThenFastBlurSpreadsOnMountedDrawable() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget(width: 100, height: 100)
        let owner = MetalStrokePixelOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            let mutation = try #require(target.mailbox.beginMutation())
            try await owner.configure(target, mutation: mutation)
            try target.mount(to: #require(view.layer), mutation: mutation)
            #expect(target.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: try DisplayGeometry(size: PAGSize(width: 100, height: 100), scale: 1),
                isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()

            let layer = try MetalGroupFixtures.layer
            let clip = FrameClip(size: try PAGSize(width: 100, height: 100), matrix: .identity)
            let glow = SampledGlow(threshold: 0.5, radius: 0, intensity: 1)
            let blur = SampledFastBlur(blurriness: 4, direction: 0, repeatEdgePixels: true)
            let commands: [FrameCommand] = [
                .solid(FrameSolid(layerID: layer, size: clip.size,
                    color: SceneColor(red: 0, green: 0, blue: 255), matrix: .identity, opacity: 1)),
                .beginGroup(FrameGroup(layerID: layer, frame: 0, clip: clip, opacity: 1,
                    application: .composite, glow: glow, fastBlur: blur)),
                .solid(FrameSolid(layerID: layer, size: try PAGSize(width: 10, height: 10),
                    color: SceneColor(red: 255, green: 0, blue: 0),
                    matrix: try .translation(x: 10, y: 20), opacity: 1)),
                .endGroup
            ]
            let frame = MetalGroupFixtures.frame(commands)
            let points = [SIMD2(8, 25), SIMD2(9, 25), SIMD2(10, 25),
                          SIMD2(15, 25), SIMD2(20, 25), SIMD2(21, 25), SIMD2(5, 5)]
            let actual = try await owner.pixels(frame, target: target, at: points)
            var plain = commands
            plain[1] = .beginGroup(FrameGroup(layerID: layer, frame: 0, clip: clip,
                opacity: 1, application: .composite, glow: glow))
            let baseline = try await owner.pixels(MetalGroupFixtures.frame(plain),
                target: target, at: points)
            #expect(actual[1].x > baseline[1].x)
            #expect(actual[2].x < baseline[2].x)
            #expect(actual[6] == baseline[6])

            // Decal的输出范围应越过预合成输入边界；Clamp仍由原边界收住。
            let edgeClip = FrameClip(size: try PAGSize(width: 20, height: 20),
                matrix: try .translation(x: 30, y: 30))
            let edgeCommands: [FrameCommand] = [
                .solid(FrameSolid(layerID: layer, size: clip.size,
                    color: SceneColor(red: 0, green: 0, blue: 255), matrix: .identity, opacity: 1)),
                .beginGroup(FrameGroup(layerID: layer, frame: 0, clip: edgeClip, opacity: 1,
                    application: .composite, glow: glow,
                    fastBlur: SampledFastBlur(blurriness: 4, direction: 0,
                                              repeatEdgePixels: false))),
                .solid(FrameSolid(layerID: layer, size: edgeClip.size,
                    color: SceneColor(red: 255, green: 0, blue: 0),
                    matrix: edgeClip.matrix, opacity: 1)),
                .endGroup
            ]
            let edgePoints = [SIMD2(29, 40), SIMD2(30, 40), SIMD2(25, 40)]
            let decal = try await owner.pixels(MetalGroupFixtures.frame(edgeCommands),
                target: target, at: edgePoints)
            var clampCommands = edgeCommands
            clampCommands[1] = .beginGroup(FrameGroup(layerID: layer, frame: 0,
                clip: edgeClip, opacity: 1, application: .composite, glow: glow,
                fastBlur: blur))
            let clamp = try await owner.pixels(MetalGroupFixtures.frame(clampCommands),
                target: target, at: edgePoints)
            #expect(decal[0].x > clamp[0].x)
            #expect(decal[2] == clamp[2])

            // 真实文件的68会走缩采路径；这里用足够宽的红区避免BGRA8把弱halo量化为零。
            let largeCommands: [FrameCommand] = [
                .solid(FrameSolid(layerID: layer, size: clip.size,
                    color: SceneColor(red: 0, green: 0, blue: 255), matrix: .identity, opacity: 1)),
                .beginGroup(FrameGroup(layerID: layer, frame: 0, clip: clip, opacity: 1,
                    application: .composite, glow: glow,
                    fastBlur: SampledFastBlur(blurriness: 68, direction: 0,
                                              repeatEdgePixels: false))),
                .solid(FrameSolid(layerID: layer, size: try PAGSize(width: 40, height: 40),
                    color: SceneColor(red: 255, green: 0, blue: 0),
                    matrix: try .translation(x: 30, y: 30), opacity: 1)),
                .endGroup
            ]
            let largePoints = [SIMD2(20, 50), SIMD2(50, 50)]
            let large = try await owner.pixels(MetalGroupFixtures.frame(largeCommands),
                target: target, at: largePoints)
            var largePlain = largeCommands
            largePlain[1] = .beginGroup(FrameGroup(layerID: layer, frame: 0,
                clip: clip, opacity: 1, application: .composite, glow: glow))
            let largeBaseline = try await owner.pixels(MetalGroupFixtures.frame(largePlain),
                target: target, at: largePoints)
            #expect(large[0].x > largeBaseline[0].x)
            #expect(large[1].x < largeBaseline[1].x)
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// 两倍显示倍率仍按预合成矩阵换算FastBlur像素sigma，真实drawable边缘应产生扩散。
    @MainActor @Test func glowFastBlurAtDoubleDisplayScale() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget(width: 100, height: 100, scale: 2)
        let owner = MetalStrokePixelOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            let mutation = try #require(target.mailbox.beginMutation())
            try await owner.configure(target, mutation: mutation)
            try target.mount(to: #require(view.layer), mutation: mutation)
            #expect(target.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: try DisplayGeometry(size: PAGSize(width: 100, height: 100), scale: 2),
                isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()

            let layer = try MetalGroupFixtures.layer
            let scale = try SceneAffine.scale(x: 2, y: 2)
            let clip = FrameClip(size: try PAGSize(width: 100, height: 100), matrix: scale)
            let glow = SampledGlow(threshold: 0.5, radius: 0, intensity: 1)
            let redMatrix = try SceneAffine.translation(x: 10, y: 20).following(scale)
            let commands: [FrameCommand] = [
                .solid(FrameSolid(layerID: layer, size: clip.size,
                    color: SceneColor(red: 0, green: 0, blue: 255), matrix: scale, opacity: 1)),
                .beginGroup(FrameGroup(layerID: layer, frame: 0, clip: clip, opacity: 1,
                    application: .composite, glow: glow,
                    fastBlur: SampledFastBlur(blurriness: 4, direction: 0,
                                              repeatEdgePixels: true))),
                .solid(FrameSolid(layerID: layer, size: try PAGSize(width: 10, height: 10),
                    color: SceneColor(red: 255, green: 0, blue: 0), matrix: redMatrix, opacity: 1)),
                .endGroup
            ]
            let frame = PreparedFrame(plan: FramePlan(time: RootSampleTime(requestedTime: .zero,
                frame: 0, representedTime: .zero),
                targetBounds: DisplayRect(x: 0, y: 0, width: 200, height: 200),
                commands: commands), images: [:], shapes: [:], texts: [:])
            let points = [SIMD2(19, 50), SIMD2(30, 50), SIMD2(5, 5)]
            let actual = try await owner.pixels(frame, target: target, at: points)
            var plain = commands
            plain[1] = .beginGroup(FrameGroup(layerID: layer, frame: 0,
                clip: clip, opacity: 1, application: .composite, glow: glow))
            let baseline = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                targetBounds: frame.plan.targetBounds, commands: plain),
                images: [:], shapes: [:], texts: [:])
            let original = try await owner.pixels(baseline, target: target, at: points)
            #expect(actual[0].x > original[0].x)
            #expect(actual[2] == original[2])
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
