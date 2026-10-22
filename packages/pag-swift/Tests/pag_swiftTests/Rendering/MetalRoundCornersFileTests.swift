#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 唯一tag27文件从公开载入到圆角后的真实路径及生产Metal输入准备。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"))
struct MetalRoundCornersFileTests {
    /// 原样文件首中末帧须保留圆角路径，渐变填充不能退回未修改路径。
    @Test func realRoundCornerFilePreparesMetal() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "wstask_prizebaoji.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let size = try PAGSize(width: 256, height: 256)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        var roundedFrames = 0
        for index in Set([Int64(0), root.durationFrames / 2, root.durationFrames - 1]).sorted() {
            let frame = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: index, rate: root.frameRate),
                targetSize: size, scale: 1, mode: .aspectFit)
            if frame.shapes.values.contains(where: { shape in
                shape.contours.contains { if case .trimmed = $0 { return true }; return false }
            }) { roundedFrames += 1 }
            let batch = try MetalFramePreparation.prepare(frame, width: 256, height: 256,
                                                          resources: resources, disablePictureCache: true)
            #expect(batch.passes.last?.attachment == nil)
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
        #expect(roundedFrames > 0)
    }

    /// 原样文件圆角后的渐变内容须在已挂载drawable产生实际非透明像素。
    @MainActor @Test func realRoundCornerFileReachesMountedDrawable() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 256, height: 256),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · RoundCorners"
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
            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "wstask_prizebaoji.pag"))
            let scene = try await PreparedScene.prepare(file.composition)
            let root = try #require(file.storage.compositions.last)
            let points = (0..<64).flatMap { row in (0..<64).map { column in
                SIMD2<Int>(2 + column * 4, 2 + row * 4)
            } }
            var visible = 0
            for index in Set([Int64(0), root.durationFrames / 2, root.durationFrames - 1]).sorted() {
                let frame = try await FramePlanner.prepare(scene,
                    at: SceneValidator.time(frame: index, rate: root.frameRate),
                    targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
                let pixels = try await owner.pixels(frame, target: target, at: points)
                if pixels.contains(where: { $0.w > 0 }) { visible += 1 }
            }
            #expect(visible > 0)
            await target.close()
            window.close()
        } catch {
            await target.close()
            window.close()
            throw error
        }
    }
}
#endif
