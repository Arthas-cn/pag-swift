#if os(macOS)
import AppKit
import Metal
import QuartzCore
import Testing
@testable import pag_swift

/// 真实图像凸出文件从公开Loader到直接根drawable的效果范围验证。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalBulgeFileTests {
    /// Bulge-unpin-s首中末帧都保留tag59命令，准备出的效果绘制写向根pass。
    @Test func realFilePreparesDirectBulgeDraw() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "Bulge-unpin-s.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        for index in Set([Int64(0), root.durationFrames / 2, root.durationFrames - 1]).sorted() {
            let frame = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: index, rate: root.frameRate),
                targetSize: try PAGSize(width: 512, height: 512), scale: 1, mode: .aspectFit)
            #expect(frame.plan.commands.contains {
                if case .image(let image) = $0 { return image.bulge != nil }
                return false
            })
            let batch = try MetalFramePreparation.prepare(frame, width: 512, height: 512,
                resources: resources, disablePictureCache: true)
            #expect(batch.passes.last?.attachment == nil)
            #expect(batch.passes.last?.draws.contains(where: { $0.bulge != nil }) == true)
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
    }

    /// 同一真实文件开启与去掉tag59时，已挂载drawable必须出现非透明且不同的实际像素。
    @MainActor @Test func realFileChangesMountedDrawablePixels() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 512, height: 512),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 512, height: 512))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget(width: 512, height: 512)
        let owner = MetalStrokePixelOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            let mutation = try #require(target.mailbox.beginMutation())
            try await owner.configure(target, mutation: mutation)
            try target.mount(to: #require(view.layer), mutation: mutation)
            #expect(target.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: try DisplayGeometry(size: PAGSize(width: 512, height: 512), scale: 1),
                isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()

            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "Bulge-unpin-s.pag"))
            let scene = try await PreparedScene.prepare(file.composition)
            let frame = try await FramePlanner.prepare(scene, at: .zero,
                targetSize: try PAGSize(width: 512, height: 512), scale: 1, mode: .aspectFit)
            let plainCommands = frame.plan.commands.map { command -> FrameCommand in
                guard case .image(let image) = command, image.bulge != nil else { return command }
                return .image(FrameImage(layerID: image.layerID, resourceID: image.resourceID,
                    pixelSize: image.pixelSize, matrix: image.matrix, clip: image.clip,
                    opacity: image.opacity, contentTime: image.contentTime))
            }
            let plain = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                targetBounds: frame.plan.targetBounds, commands: plainCommands),
                images: frame.images, shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
            let points = (0..<64).flatMap { row in (0..<64).map { column in
                SIMD2<Int>(4 + column * 8, 4 + row * 8)
            } }
            let actual = try await owner.pixels(frame, target: target, at: points)
            let original = try await owner.pixels(plain, target: target, at: points)
            #expect(actual.contains { $0.w > 0 })
            #expect(zip(actual, original).contains { $0.0 != $0.1 })
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
