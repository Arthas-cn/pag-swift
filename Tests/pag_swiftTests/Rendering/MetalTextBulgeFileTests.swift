#if os(macOS)
import AppKit
import Metal
import QuartzCore
import Testing
@testable import pag_swift

/// 五份真实Text层Bulge资源的局部字形附件和根drawable输入验收。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalTextBulgeFileTests {
    /// 首中末帧必须由完整字形轮次进入Bulge局部工作，根pass直接绘制并归还附件。
    @Test(arguments: ["bulgetext.pag", "text1.pag", "text2.pag", "text3.pag", "text4.pag"])
    func realFilesPrepareBoundedTextInput(_ name: String) async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        var effects = 0
        for index in Set([Int64(0), root.durationFrames / 2, root.durationFrames - 1]).sorted() {
            let frame = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: index, rate: root.frameRate),
                targetSize: try PAGSize(width: 512, height: 512), scale: 1, mode: .aspectFit)
            effects += frame.plan.commands.filter {
                if case .textBulge = $0 { return true }
                return false
            }.count
            let batch = try MetalFramePreparation.prepare(frame, width: 512, height: 512,
                resources: resources, disablePictureCache: true)
            #expect(batch.passes.last?.attachment == nil)
            let loans = batch.textBulgeWorks.map(\.loan) +
                batch.dropShadowWorks.flatMap { $0.content.textBulgeWorks.map(\.loan) }
            #expect(!loans.isEmpty)
            #expect(batch.dropShadowWorks.allSatisfy {
                $0.contentLoan.texture.width * $0.contentLoan.texture.height < 512 * 512
            })
            print("PAG_TEXT_BULGE_LOANS file=\(name) frame=\(index) sizes=\(loans.map { "\($0.texture.width)x\($0.texture.height)" })")
            print("PAG_TEXT_BULGE_SHADOW file=\(name) frame=\(index) sizes=\(batch.dropShadowWorks.map { "\($0.contentLoan.texture.width)x\($0.contentLoan.texture.height)" })")
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
        #expect(effects > 0)
        print("PAG_TEXT_BULGE file=\(name) effects=\(effects)")
    }

    /// 五份真实文件在同一挂载drawable保留投影，只移除Bulge后须看到画面差分。
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

            for name in ["bulgetext.pag", "text1.pag", "text2.pag", "text3.pag", "text4.pag"] {
                let step = name == "text4.pag" ? 2 : 8
                let points = (0..<(512 / step)).flatMap { row in (0..<(512 / step)).map { column in
                    SIMD2<Int>(step / 2 + column * step, step / 2 + row * step)
                } }
                let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
                let scene = try await PreparedScene.prepare(file.composition)
                let root = try #require(file.storage.compositions.last)
                var visible = 0
                var differences = 0
                let indices = name == "text4.pag" ? [Int64(0)] :
                    Set([Int64(0), root.durationFrames / 2, root.durationFrames - 1]).sorted()
                for index in indices {
                    let frame = try await FramePlanner.prepare(scene,
                        at: SceneValidator.time(frame: index, rate: root.frameRate),
                        targetSize: try PAGSize(width: 512, height: 512), scale: 1, mode: .aspectFit)
                    var removed = 0
                    let originalCommands = frame.plan.commands.flatMap { command -> [FrameCommand] in
                        guard case .textBulge(let effect) = command else { return [command] }
                        removed += 1
                        // 投影作用域仍完整保留，仅恢复效果之前的背景与文字轮次。
                        return (effect.background.map { [.shape($0)] } ?? []) + effect.passes.map(FrameCommand.text)
                    }
                    #expect(removed > 0)
                    let original = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                        targetBounds: frame.plan.targetBounds, commands: originalCommands),
                        images: frame.images, shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
                    var count = 0
                    for start in stride(from: 0, to: points.count, by: 4_096) {
                        let part = Array(points[start..<min(start + 4_096, points.count)])
                        let activePixels = try await owner.pixels(frame, target: target, at: part)
                        let plainPixels = try await owner.pixels(original, target: target, at: part)
                        visible += activePixels.filter { $0.w > 0 }.count
                        count += zip(activePixels, plainPixels).filter { $0.0 != $0.1 }.count
                    }
                    differences += count
                    print("PAG_TEXT_BULGE_FRAME file=\(name) frame=\(index) differing=\(count)")
                }
                print("PAG_TEXT_BULGE_PIXELS file=\(name) visible=\(visible) differing=\(differences)")
                #expect(visible > 0 && differences > 0)
            }
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
