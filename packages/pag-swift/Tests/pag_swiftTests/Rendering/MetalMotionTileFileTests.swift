#if os(macOS)
import AppKit
import Foundation
import Metal
import QuartzCore
import Testing
@testable import pag_swift

/// 真实tag56图片从公开载入、逐帧计划到已挂载Metal目标的平铺结果。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalMotionTileFileTests {
    /// motiontile1的tag56必须进入图像命令，最终批次直接以根drawable为目标。
    @Test func realFilePreparesDirectTileDraw() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "motiontile1.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero,
            targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
        #expect(frame.plan.commands.contains {
            if case .image(let image) = $0 { return image.motionTile != nil }
            return false
        })
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        let batch = try MetalFramePreparation.prepare(frame, width: 256, height: 256,
            resources: resources, disablePictureCache: true)
        #expect(batch.passes.last?.attachment == nil)
        #expect(batch.passes.last?.draws.contains(where: { $0.motionTile != nil }) == true)
        batch.releaseTransients()
        #expect(resources.groups.activeBytes == 0)
    }

    /// 真实文件平铺有像素差异；同一drawable核对镜像、正phase和单子组alpha下的颜色金值。
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

            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "motiontile1.pag"))
            let scene = try await PreparedScene.prepare(file.composition)
            let frame = try await FramePlanner.prepare(scene, at: .zero,
                targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
            let plainCommands = frame.plan.commands.map { command -> FrameCommand in
                guard case .image(let image) = command, image.motionTile != nil else { return command }
                return .image(FrameImage(layerID: image.layerID, resourceID: image.resourceID,
                    pixelSize: image.pixelSize, matrix: image.matrix, clip: image.clip,
                    opacity: image.opacity, contentTime: image.contentTime))
            }
            let plain = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                targetBounds: frame.plan.targetBounds, commands: plainCommands),
                images: frame.images, shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
            let points = (0..<32).flatMap { row in (0..<32).map { column in
                SIMD2<Int>(4 + column * 8, 4 + row * 8)
            } }
            let tiledPixels = try await owner.pixels(frame, target: target, at: points)
            let plainPixels = try await owner.pixels(plain, target: target, at: points)
            #expect(tiledPixels.contains { $0.w > 0 })
            #expect(zip(tiledPixels, plainPixels).contains { $0.0 != $0.1 })

            // 四段输出必须按镜像奇偶读成红、红、绿、绿；普通重复会读成绿、红、绿、红。
            let mirrored = try Self.tileFixture(mirror: true)
            let columns = try await owner.pixels(mirrored, target: target,
                at: [SIMD2(20, 80), SIMD2(60, 80), SIMD2(100, 80), SIMD2(140, 80)])
            #expect(columns == [SIMD4(255, 0, 0, 255), SIMD4(255, 0, 0, 255),
                                SIMD4(0, 255, 0, 255), SIMD4(0, 255, 0, 255)])
            let phase = try Self.tileFixture(mirror: false, phase: 180, horizontal: true)
            let staggered = try await owner.pixels(phase, target: target,
                at: [SIMD2(60, 20), SIMD2(60, 60)])
            #expect(staggered == [SIMD4(0, 255, 0, 255), SIMD4(255, 0, 0, 255)])
            let translucent = try Self.tileFixture(mirror: false, groupOpacity: 0.5)
            let faded = try await owner.pixels(translucent, target: target,
                at: [SIMD2(20, 80), SIMD2(60, 80)])
            #expect(faded == [SIMD4(0, 128, 0, 128), SIMD4(128, 0, 0, 128)])
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// 构造两色输入的效果语义图，仅验证着色器取样，不声称它是合法PAG字节文件。
    private static func tileFixture(mirror: Bool, phase: Double = 0,
                                    horizontal: Bool = false,
                                    groupOpacity: Double? = nil) throws -> PreparedFrame {
        var pixels = Data()
        for _ in 0..<8 {
            for column in 0..<8 {
                pixels.append(contentsOf: column < 4 ? [255, 0, 0, 255] : [0, 255, 0, 255])
            }
        }
        let identity = try DocumentIdentity(data: pixels)
        let size = try PAGSize(width: 8, height: 8)
        let image = PAGImage(storage: StillImageStorage(identity: identity, size: size,
            pixels: pixels, bytesPerRow: 32, sourceType: "pag.synthetic", sourceOrientation: 1))
        let sampled = SampledMotionTile(center: ScenePoint(x: 4, y: 4), tileWidth: 100,
            tileHeight: 100, outputWidth: 200, outputHeight: 200,
            mirrorEdges: mirror, phase: phase, horizontalPhaseShift: horizontal)
        let tile = try FrameMotionTile(sampled, placement: .identity, pixelSize: size)
        let matrix = try SceneAffine.scale(x: 10, y: 10).following(.translation(x: 40, y: 40))
        let rootSize = try PAGSize(width: 256, height: 256)
        let group = FrameGroup(layerID: nil, frame: 0,
            clip: FrameClip(size: rootSize, matrix: .identity), opacity: 1)
        let command = FrameImage(layerID: try MetalGroupFixtures.layer,
            resourceID: identity, pixelSize: size, matrix: matrix,
            clip: nil, opacity: 1, contentTime: .zero, motionTile: tile)
        var commands: [FrameCommand] = [.beginGroup(group)]
        if let groupOpacity {
            commands.append(.beginOpacityGroup(FrameOpacityGroup(layerID: try MetalGroupFixtures.layer,
                opacity: groupOpacity, application: .composite)))
        }
        commands.append(.image(command))
        if groupOpacity != nil { commands.append(.endOpacityGroup) }
        commands.append(.endGroup)
        let plan = FramePlan(time: RootSampleTime(requestedTime: .zero,
            frame: 0, representedTime: .zero),
            targetBounds: DisplayRect(x: 0, y: 0, width: 256, height: 256),
            commands: commands)
        return PreparedFrame(plan: plan, images: [identity: image], shapes: [:], texts: [:])
    }
}
#endif
