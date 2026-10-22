#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 静态文字快照直接写入真实窗口 drawable，核对首帧、命中和禁用缓存时的覆盖差异。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct MetalTextPicturePixelTests {
    /// TEXT04真实文件的文字必须从Loader进入同一局部纹理，后续帧命中且实际窗口像素稳定。
    @MainActor @Test func realTextFileUsesDrawableSnapshot() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 170, y: 170, width: 360, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · TEXT04 Picture pixels"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 640))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget(width: 360, height: 640)
        let owner = MetalStrokePixelOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            let mutation = try #require(target.mailbox.beginMutation())
            try await owner.configure(target, mutation: mutation)
            try target.mount(to: #require(view.layer), mutation: mutation)
            #expect(target.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: try DisplayGeometry(size: PAGSize(width: 360, height: 640), scale: 1),
                isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()

            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
            let scene = try await PreparedScene.prepare(file.composition)
            let frame = try await FramePlanner.prepare(scene, at: .zero,
                targetSize: try PAGSize(width: 360, height: 640), scale: 1, mode: .aspectFit)
            let points = [SIMD2(120, 280), SIMD2(160, 280), SIMD2(200, 280), SIMD2(240, 280),
                          SIMD2(120, 300), SIMD2(160, 300), SIMD2(200, 300), SIMD2(240, 300),
                          SIMD2(120, 320), SIMD2(160, 320), SIMD2(200, 320), SIMD2(240, 320),
                          SIMD2(120, 340), SIMD2(160, 340), SIMD2(200, 340), SIMD2(240, 340)]
            let first = try await owner.pixels(frame, target: target, at: points, enablePictures: true)
            #expect(await owner.lastPicturePasses == 1)
            let hit = try await owner.pixels(frame, target: target, at: points, enablePictures: true)
            #expect(await owner.lastPicturePasses == 0 && hit == first)
            let fallback = try await owner.pixels(frame, target: target, at: points,
                                                  enablePictures: true, disablePictureCache: true)
            #expect(await owner.lastPicturePasses == 0)
            #expect(await owner.retainedPictureCount == 1)
            // 真实TEXT04源色为金橙描边和黑色填充；选空白、填充、描边与抗锯齿边缘各一点。
            let snapshotGold: [(Int, SIMD4<UInt8>)] = [
                (0, .zero), (5, SIMD4(0, 0, 0, 255)),
                (9, SIMD4(241, 173, 0, 255)), (8, SIMD4(0, 0, 0, 84))
            ]
            let fallbackGold: [(Int, SIMD4<UInt8>)] = [
                (0, .zero), (5, SIMD4(0, 0, 0, 255)),
                (9, SIMD4(255, 183, 0, 255)), (8, SIMD4(0, 0, 0, 43))
            ]
            for (pixels, gold) in [(first, snapshotGold), (hit, snapshotGold), (fallback, fallbackGold)] {
                for (index, expected) in gold {
                    for channel in 0..<4 {
                        #expect(abs(Int(pixels[index][channel]) - Int(expected[channel])) <= 1,
                                "TEXT04实际drawable像素\(pixels[index])，基线\(expected)")
                    }
                }
            }
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// 两个近乎同位的描边填充字形先合成到局部纹理，外层半透明只应用一次；回退仍逐 draw 继承。
    @MainActor @Test func overlappingGlyphsGenerateHitAndPreserveFallback() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · Text Picture pixels"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget()
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

            var style = try TextFixtures.source("HH").style
            style.fontSize = 40
            style.strokeWidth = 10
            style.strokeColor = try PAGColor(red: 1, green: 0, blue: 0)
            style.fillColor = try PAGColor(red: 1, green: 0, blue: 0)
            style.tracking = -725
            let transform = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
                position: ScenePoint(x: 25, y: 65), scale: .one, rotation: 0, opacity: 128))
            let source = try SceneFixtures.composition(5, layers: [SceneFixtures.layer(5,
                transform: transform, content: .text(try TextFixtures.source("HH", style: style)))])
            let scene = try await PreparedScene.prepare(SceneFixtures.build([source]).composition)
            let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: source.size,
                                                       scale: 1, mode: .none)
            let glyphs = try #require(frame.texts.values.first?.glyphs)
            #expect(glyphs.count == 2 && abs(glyphs[1].matrix.tx - glyphs[0].matrix.tx) < 1)
            let points = [SIMD2(30, 45), SIMD2(40, 45), SIMD2(20, 45)]
            let first = try await owner.pixels(frame, target: target, at: points, enablePictures: true)
            #expect(await owner.lastPicturePasses == 1)
            #expect(await owner.retainedPictureCount == 1)
            let hit = try await owner.pixels(frame, target: target, at: points, enablePictures: true)
            #expect(await owner.lastPicturePasses == 0 && hit == first)
            let fallback = try await owner.pixels(frame, target: target, at: points,
                                                  enablePictures: true, disablePictureCache: true)
            #expect(await owner.lastPicturePasses == 0)
            let snapshotGold = [SIMD4<UInt8>(128, 0, 0, 128), SIMD4<UInt8>(128, 0, 0, 128), .zero]
            let fallbackGold = [SIMD4<UInt8>(239, 0, 0, 239), SIMD4<UInt8>(192, 0, 0, 192), .zero]
            // 两个字形与描边先在局部纹理变不透明；原路径则在drawable逐次叠加128/255。
            #expect(first == snapshotGold && hit == snapshotGold)
            for (actual, gold) in zip(fallback, fallbackGold) {
                for channel in 0..<4 {
                    #expect(abs(Int(actual[channel]) - Int(gold[channel])) <= 1,
                            "逐draw回退\(actual)，预乘通道金值\(gold)")
                }
            }

            var changedStyle = style
            changedStyle.strokeColor = try PAGColor(red: 0, green: 0, blue: 1)
            let changedSource = try SceneFixtures.composition(5, layers: [SceneFixtures.layer(5,
                transform: transform, content: .text(try TextFixtures.source("HH", style: changedStyle)))])
            let changedScene = try await PreparedScene.prepare(SceneFixtures.build([changedSource]).composition)
            let changedFrame = try await FramePlanner.prepare(changedScene, at: .zero,
                targetSize: changedSource.size, scale: 1, mode: .none)
            let originalMarker = try #require(frame.plan.commands.compactMap { command -> FramePicture? in
                if case .beginPicture(let marker) = command { marker } else { nil }
            }.first)
            let changedMarker = try #require(changedFrame.plan.commands.compactMap { command -> FramePicture? in
                if case .beginPicture(let marker) = command { marker } else { nil }
            }.first)
            guard case .text(let originalID, _) = originalMarker.content,
                  case .text(let changedID, _) = changedMarker.content else {
                Issue.record("颜色编辑应保持Text Picture候选")
                return
            }
            #expect(originalMarker.document == changedMarker.document &&
                    originalMarker.source == changedMarker.source &&
                    originalMarker.matrix == changedMarker.matrix && originalID != changedID)
            let changedPixels = try await owner.pixels(changedFrame, target: target,
                                                       at: [SIMD2(40, 45)], enablePictures: true)
            #expect(await owner.lastPicturePasses == 1)
            // 源、字形和矩阵均相同，仅描边由红改蓝；旧纹理若误命中便仍会得到红色。
            #expect(changedPixels == [SIMD4(0, 0, 128, 128)] && changedPixels != [first[1]])
            #expect(await owner.retainedPictureCount == 2)

            let turned = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
                position: ScenePoint(x: 20, y: 25), scale: ScenePoint(x: 1.5, y: 1.5),
                rotation: 90, opacity: 128))
            let rotatedSource = try SceneFixtures.composition(6, layers: [SceneFixtures.layer(6,
                transform: turned, content: .text(try TextFixtures.source("HH", style: style)))])
            let rotatedScene = try await PreparedScene.prepare(SceneFixtures.build([rotatedSource]).composition)
            let rotatedFrame = try await FramePlanner.prepare(rotatedScene, at: .zero,
                targetSize: rotatedSource.size, scale: 1, mode: .none)
            let rotatedPoints = [SIMD2(50, 33), SIMD2(50, 48), SIMD2(50, 18), SIMD2(65, 33)]
            let rotatedPicture = try await owner.pixels(rotatedFrame, target: target,
                                                        at: rotatedPoints, enablePictures: true)
            #expect(await owner.lastPicturePasses == 1)
            let rotatedFallback = try await owner.pixels(rotatedFrame, target: target,
                at: rotatedPoints, enablePictures: true, disablePictureCache: true)
            #expect(rotatedPicture == [SIMD4(128, 0, 0, 128), SIMD4(128, 0, 0, 128),
                                       .zero, SIMD4(128, 0, 0, 128)])
            let rotatedFallbackGold = [SIMD4<UInt8>(239, 0, 0, 239), SIMD4(192, 0, 0, 192),
                                       .zero, SIMD4(192, 0, 0, 192)]
            for (actual, gold) in zip(rotatedFallback, rotatedFallbackGold) {
                for channel in 0..<4 {
                    #expect(abs(Int(actual[channel]) - Int(gold[channel])) <= 1)
                }
            }

            let rotatedClip = FrameClip(size: try PAGSize(width: 20, height: 20),
                matrix: try SceneAffine.rotation(degrees: 45).following(.translation(x: 55, y: 11)))
            let ancestor = FrameGroup(layerID: nil, frame: 0, clip: rotatedClip, opacity: 1)
            var clippedCommands = rotatedFrame.plan.commands
            clippedCommands.insert(.beginGroup(ancestor), at: 1)
            clippedCommands.insert(.endGroup, at: clippedCommands.count - 1)
            let clipped = PreparedFrame(plan: FramePlan(time: rotatedFrame.plan.time,
                targetBounds: rotatedFrame.plan.targetBounds, commands: clippedCommands),
                images: rotatedFrame.images, shapes: rotatedFrame.shapes, texts: rotatedFrame.texts)
            // (65,33)在旋转裁剪的AABB内、真实菱形外；它原本是红色字形，快照绘回也必须被裁掉。
            let clipPoints = [SIMD2(50, 33), SIMD2(65, 33)]
            let clippedPicture = try await owner.pixels(clipped, target: target,
                at: clipPoints, enablePictures: true, revision: 1)
            #expect(await owner.lastPicturePasses == 1)
            let clippedFallback = try await owner.pixels(clipped, target: target,
                at: clipPoints, enablePictures: true, disablePictureCache: true, revision: 1)
            #expect(clippedPicture == [SIMD4(128, 0, 0, 128), .zero])
            #expect(abs(Int(clippedFallback[0].w) - 239) <= 1 && clippedFallback[1] == .zero)
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
