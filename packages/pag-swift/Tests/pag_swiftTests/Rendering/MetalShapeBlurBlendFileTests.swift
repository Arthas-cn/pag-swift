#if os(macOS)
import AppKit
import Metal
import QuartzCore
import Testing
@testable import pag_swift

/// 真实tougao的Shape局部FastBlur及HardLight在Metal准备与已挂载drawable中的行为。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalShapeBlurBlendFileTests {
    /// 根合成全部源帧均能准备，实际出现且可见的Shape模糊应有局部工作并完整归还。
    @Test func allSourceFramesPrepareMetal() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "tougao.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let size = try PAGSize(width: 256, height: 256)
        let resources = try MetalResources(device: #require(MTLCreateSystemDefaultDevice()))
        var planned = 0, materialized = 0
        for index in 0..<root.durationFrames {
            let frame = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: index, rate: root.frameRate),
                targetSize: size, scale: 1, mode: .aspectFit)
            let batch = try MetalFramePreparation.prepare(frame, width: 256, height: 256,
                resources: resources, disablePictureCache: true)
            #expect(batch.passes.last?.draws.contains(where: { $0.hardLightBlend }) == true)
            if frame.plan.commands.contains(where: {
                if case .beginShapeBlurBlend = $0 { true } else { false }
            }) { planned += 1 }
            if Self.countShapeWorks(in: batch) > 0 { materialized += 1 }
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
        print("PAG_TOUGAO_FRAMES total=\(root.durationFrames) planned=\(planned) visible=\(materialized)")
        #expect(planned > 0 && materialized > 0)
    }

    /// 轨道遮罩会把Shape工作放入拥有者或源子批次，统计须递归穿过局部批次。
    private static func countShapeWorks(in batch: MetalFrameBatch) -> Int {
        batch.shapeBlurBlendWorks.count + batch.trackMatteWorks.reduce(0) { count, work in
            count + countShapeWorks(in: work.content) + countShapeWorks(in: work.source)
        }
    }

    /// 中帧直接写已挂载drawable，真实动态Blur与零Blur应留下可观察像素差异。
    @MainActor @Test func shapeBlurChangesMountedDrawablePixels() async throws {
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

            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "tougao.pag"))
            let scene = try await PreparedScene.prepare(file.composition)
            let root = try #require(file.storage.compositions.last)
            let frame = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: root.durationFrames / 2, rate: root.frameRate),
                targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
            let zeroCommands = frame.plan.commands.map { command -> FrameCommand in
                guard case .beginShapeBlurBlend(let effect) = command else { return command }
                return .beginShapeBlurBlend(FrameShapeBlurBlend(layerID: effect.layerID,
                    matrix: effect.matrix,
                    blur: SampledFastBlur(blurriness: 0, direction: 0, repeatEdgePixels: false),
                    opacity: effect.opacity, blendMode: effect.blendMode))
            }
            let unblurred = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                targetBounds: frame.plan.targetBounds, commands: zeroCommands),
                images: frame.images, shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
            let points = (0..<64).flatMap { row in (0..<64).map { column in
                SIMD2<Int>(2 + column * 4, 2 + row * 4)
            } }
            let pixels = try await owner.pixels(frame, target: target, at: points)
            let withoutBlur = try await owner.pixels(unblurred, target: target, at: points)
            #expect(pixels.contains { $0.w > 0 })
            let differences = zip(pixels, withoutBlur).filter { $0.0 != $0.1 }.count
            print("PAG_TOUGAO_BLUR_PIXELS frame=\(root.durationFrames / 2) differing=\(differences)")
            #expect(differences > 0)
            let layer = try MetalGroupFixtures.layer
            let background = FrameSolid(layerID: layer,
                size: try PAGSize(width: 256, height: 256),
                color: SceneColor(red: 0, green: 0, blue: 255), matrix: .identity, opacity: 1)
            let gray = FrameSolid(layerID: layer, size: try PAGSize(width: 20, height: 20),
                color: SceneColor(red: 127, green: 127, blue: 127),
                matrix: try .translation(x: 10, y: 10), opacity: 1)
            let blend = FrameShapeBlurBlend(layerID: layer, matrix: .identity,
                blur: SampledFastBlur(blurriness: 0, direction: 0, repeatEdgePixels: false), opacity: 1)
            let gold = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                targetBounds: frame.plan.targetBounds,
                commands: [.solid(background), .beginShapeBlurBlend(blend), .solid(gray), .endShapeBlurBlend]),
                images: [:], shapes: [:], texts: [:])
            let blended = try await owner.pixels(gold, target: target, at: [SIMD2(15, 15), SIMD2(5, 5)])
            // 127灰色HardLight在不透明蓝背景上近似保持蓝；若误用SrcOver会变为灰色。
            #expect(blended[0].x <= 2 && blended[0].y <= 2 && blended[0].z >= 252)
            #expect(blended[1] == SIMD4(0, 0, 255, 255))
            let white = FrameSolid(layerID: layer, size: gray.size,
                color: SceneColor(red: 255, green: 255, blue: 255),
                matrix: gray.matrix, opacity: 1)
            let matte = FrameTrackMatte(ownerID: layer, mode: .alpha,
                ownerBlendMode: .hardLight, ownerOpacity: 1)
            let inner = FrameShapeBlurBlend(layerID: layer, matrix: .identity,
                blur: blend.blur, opacity: 1, blendMode: .normal)
            let matteCommands: [FrameCommand] = [.solid(background), .beginTrackMatte(matte),
                .solid(white), .endTrackMatteSource,
                .beginShapeBlurBlend(inner), .solid(gray), .endShapeBlurBlend, .endTrackMatte]
            let matteFrame = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                targetBounds: frame.plan.targetBounds, commands: matteCommands),
                images: [:], shapes: [:], texts: [:])
            let mattePixels = try await owner.pixels(matteFrame, target: target,
                at: [SIMD2(15, 15), SIMD2(5, 5)])
            // 上游外层blend包住Track Matte：遮罩后的灰色仍应以HardLight保持蓝背景。
            #expect(mattePixels[0].x <= 2 && mattePixels[0].y <= 2 && mattePixels[0].z >= 252)
            #expect(mattePixels[1] == SIMD4(0, 0, 255, 255))
            var normalCommands = matteCommands
            normalCommands[1] = .beginTrackMatte(FrameTrackMatte(ownerID: layer, mode: .alpha))
            let normalFrame = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                targetBounds: frame.plan.targetBounds, commands: normalCommands),
                images: [:], shapes: [:], texts: [:])
            let normalPixels = try await owner.pixels(normalFrame, target: target, at: [SIMD2(15, 15)])
            #expect((125...129).contains(normalPixels[0].x) &&
                    (125...129).contains(normalPixels[0].y) &&
                    (125...129).contains(normalPixels[0].z))
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
