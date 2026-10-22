#if os(macOS)
import AppKit
import Foundation
import Metal
import QuartzCore
import Testing
@testable import pag_swift

/// 两份真实tag58图像文件按各自效果顺序准备根drawable输入。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalCornerPinFileTests {
    /// CornerPin与前置MotionTile或后置Bulge的首中末帧必须保留顺序且归还附件。
    @Test(arguments: ["motiontile_text_corner.pag", "cornerpin-bulge.pag"])
    func realFilesPrepareDirectCornerPinDraw(_ name: String) async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        for index in Set([Int64(0), root.durationFrames / 2, root.durationFrames - 1]).sorted() {
            let frame = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: index, rate: root.frameRate),
                targetSize: try PAGSize(width: 512, height: 512), scale: 1, mode: .aspectFit)
            #expect(frame.plan.commands.contains {
                if case .image(let image) = $0 { return image.cornerPin != nil }
                return false
            })
            let batch = try MetalFramePreparation.prepare(frame, width: 512, height: 512,
                resources: resources, disablePictureCache: true)
            #expect(batch.passes.last?.attachment == nil)
            #expect(batch.passes.last?.draws.contains(where: { $0.cornerPin != nil }) == true)
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
    }

    /// 动画四角不能只在三时刻有效；两份真实文件的全部根源帧须可准备并归还附件。
    @Test(arguments: ["motiontile_text_corner.pag", "cornerpin-bulge.pag"])
    func allSourceFramesPrepare(_ name: String) async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        for index in 0..<root.durationFrames {
            let frame = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: index, rate: root.frameRate),
                targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
            let batch = try MetalFramePreparation.prepare(frame, width: 256, height: 256,
                resources: resources, disablePictureCache: true)
            #expect(batch.passes.last?.attachment == nil)
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
        print("PAG_CORNER_PIN_FRAMES file=\(name) count=\(root.durationFrames)")
    }

    /// 两份真实文件的组合效果须在同一挂载drawable显示内容并与原图产生像素差异。
    @MainActor @Test func realFilesChangeMountedDrawablePixels() async throws {
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

            let points = (0..<64).flatMap { row in (0..<64).map { column in
                SIMD2<Int>(4 + column * 8, 4 + row * 8)
            } }
            for name in ["motiontile_text_corner.pag", "cornerpin-bulge.pag"] {
                let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
                let scene = try await PreparedScene.prepare(file.composition)
                let root = try #require(file.storage.compositions.last)
                var differences = 0
                var visible = 0
                for index in Set([Int64(0), root.durationFrames / 2, root.durationFrames - 1]).sorted() {
                    let frame = try await FramePlanner.prepare(scene,
                        at: SceneValidator.time(frame: index, rate: root.frameRate),
                        targetSize: try PAGSize(width: 512, height: 512), scale: 1, mode: .aspectFit)
                    let plainCommands = frame.plan.commands.map { command -> FrameCommand in
                        guard case .image(let image) = command, image.cornerPin != nil else { return command }
                        return .image(FrameImage(layerID: image.layerID, resourceID: image.resourceID,
                            pixelSize: image.pixelSize, matrix: image.matrix, clip: image.clip,
                            opacity: image.opacity, contentTime: image.contentTime))
                    }
                    let plain = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                        targetBounds: frame.plan.targetBounds, commands: plainCommands),
                        images: frame.images, shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
                    let actual = try await owner.pixels(frame, target: target, at: points)
                    let original = try await owner.pixels(plain, target: target, at: points)
                    visible += actual.filter { $0.w > 0 }.count
                    differences += zip(actual, original).filter { $0.0 != $0.1 }.count
                }
                print("PAG_CORNER_PIN_PIXELS file=\(name) visible=\(visible) differing=\(differences)")
                #expect(visible > 0 && differences > 0)
            }

            // 两色合成输入独立锁定逆投影与四角外透明，不能只依赖真实文件相对原图的差异。
            let perspective = try Self.perspectiveFixture()
            let colors = try await owner.pixels(perspective, target: target,
                at: [SIMD2(55, 55), SIMD2(103, 55), SIMD2(110, 110)])
            #expect(colors == [SIMD4(255, 0, 0, 255), SIMD4(0, 255, 0, 255), SIMD4(0, 0, 0, 0)])
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// 合成两色图只验证Metal的投影采样，不冒充真实PAG编码文件。
    private static func perspectiveFixture() throws -> PreparedFrame {
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
        let sampled = SampledCornerPin(upperLeft: ScenePoint(x: 40, y: 40),
            upperRight: ScenePoint(x: 120, y: 40), lowerLeft: ScenePoint(x: 40, y: 120),
            lowerRight: ScenePoint(x: 95, y: 95))
        let corner = try FrameCornerPin(sampled, placement: .identity)
        let rootSize = try PAGSize(width: 512, height: 512)
        let group = FrameGroup(layerID: nil, frame: 0,
            clip: FrameClip(size: rootSize, matrix: .identity), opacity: 1)
        let command = FrameImage(layerID: nil, resourceID: identity, pixelSize: size,
            matrix: .identity, clip: nil, opacity: 1, contentTime: .zero, cornerPin: corner)
        let plan = FramePlan(time: RootSampleTime(requestedTime: .zero,
            frame: 0, representedTime: .zero),
            targetBounds: DisplayRect(x: 0, y: 0, width: 512, height: 512),
            commands: [.beginGroup(group), .image(command), .endGroup])
        return PreparedFrame(plan: plan, images: [identity: image], shapes: [:], texts: [:])
    }
}
#endif
