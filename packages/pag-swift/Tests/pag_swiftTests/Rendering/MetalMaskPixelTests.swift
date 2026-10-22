#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 用真实窗口drawable检查普通路径逐draw覆盖、补集与内容Picture的不同消费粒度。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct MetalMaskPixelTests {
    /// AudioMarker真实tag14跨四段图片子合成进入显示计划；蒙版包住子树并在drawable留下可见像素。
    @MainActor @Test func realAudioMarkerMaskReachesDrawable() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
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
            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "AudioMarker.pag"))
            let scene = try await PreparedScene.prepare(file.composition)
            let root = file.storage.compositions[file.storage.rootIndex]
            let points = [SIMD2(251, 285), SIMD2(251, 189), SIMD2(174, 285),
                          SIMD2(97, 285), SIMD2(251, 458), SIMD2(105, 139)]
            var visibleSamples = 0
            for frame: Int64 in [0, 140, 300, 425] {
                let time = try SceneValidator.time(frame: frame, rate: root.frameRate)
                let full = try await FramePlanner.prepare(scene, at: time,
                    targetSize: PAGSize(width: 360, height: 640), scale: 1, mode: .aspectFit)
                let commands = full.plan.commands
                let begin = try #require(commands.firstIndex { if case .beginMask = $0 { true } else { false } })
                let end = try #require(commands.firstIndex { if case .endMask = $0 { true } else { false } })
                guard case .beginMask(let mask) = commands[begin] else { continue }
                #expect(mask.layerID.path == [330] && !mask.isInverted && end > begin + 2)
                // 同一真实帧只抽取被蒙版包住的预合成，避免兄弟视频/图片遮挡路径内外取点。
                let isolated = PreparedFrame(plan: FramePlan(time: full.plan.time,
                    targetBounds: full.plan.targetBounds,
                    commands: [commands[0]] + Array(commands[begin...end]) + [.endGroup]),
                    images: full.images, shapes: full.shapes, texts: full.texts, videos: full.videos)
                let pixels = try await owner.pixels(isolated, target: target, at: points)
                visibleSamples += pixels.prefix(3).filter { $0.w > 0 }.count
                #expect(pixels.suffix(3).allSatisfy { $0.w == 0 })
            }
            #expect(visibleSamples > 0)
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// mask半像素边缘遇到两次重叠paint和外层alpha时，快照成功与回退应有不同独立RGBA金值。
    @MainActor @Test func maskCoverageFollowsActualDrawAndPictureBoundary() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 90, y: 90, width: 100, height: 100),
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
            let normal = try await plan(inverted: false)
            let points = [SIMD2(40, 50), SIMD2(50, 50), SIMD2(70, 50)]
            let fallback = try await owner.pixels(normal, target: target, at: points,
                                                  enablePictures: true, disablePictureCache: true)
            #expect(await owner.lastPicturePasses == 0)
            let first = try await owner.pixels(normal, target: target, at: points, enablePictures: true)
            #expect(await owner.lastPicturePasses == 1)
            let hit = try await owner.pixels(normal, target: target, at: points, enablePictures: true)
            #expect(await owner.lastPicturePasses == 0 && hit == first)
            // ShapeRenderer的Below以逆序绘制，红色在蓝色上；a=128/255、边缘c=0.5。
            // 回退两次SrcOver，成功Picture只把预合成的红色内容绘回一次。
            try expect(fallback, near: [SIMD4(128, 0, 64, 192), SIMD4(64, 0, 48, 112), .zero])
            try expect(first, near: [SIMD4(128, 0, 0, 128), SIMD4(64, 0, 0, 64), .zero])

            let inverse = try await plan(inverted: true)
            let inversePixels = try await owner.pixels(inverse, target: target, at: points,
                                                       enablePictures: true, disablePictureCache: true)
            try expect(inversePixels, near: [.zero, SIMD4(64, 0, 48, 112), SIMD4(128, 0, 64, 192)])
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// 零面积有效路径正向隐藏本层、反向保留本层，退出蒙版后兄弟层始终可见。
    @MainActor @Test func zeroAreaMaskRestoresSiblingOnDrawable() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 110, y: 110, width: 100, height: 100),
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
            let path = try SourcePath(verbs: [.move, .line, .line, .close], points: [
                ScenePoint(x: 20, y: 0), ScenePoint(x: 20, y: 20), ScenePoint(x: 20, y: 40)
            ])
            let points = [SIMD2(20, 30), SIMD2(70, 30)]
            for inverted in [false, true] {
                let mask = FrameMask(layerID: try MetalGroupFixtures.layer, source: .path(path),
                                     isInverted: inverted, matrix: .identity)
                let frame = MetalGroupFixtures.frame([.beginMask(mask), try MetalGroupFixtures.solid(),
                    .endMask, try MetalGroupFixtures.solid(x: 60)])
                let pixels = try await owner.pixels(frame, target: target, at: points)
                try expect(pixels, near: [inverted ? SIMD4(255, 0, 0, 255) : .zero,
                                          SIMD4(255, 0, 0, 255)])
            }
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// 构造静态双paint内容和外部路径蒙版；源身份相同但补集位不同仍不可复用错误裁剪。
    private func plan(inverted: Bool) async throws -> PreparedFrame {
        let path = try SourcePath(verbs: [.move, .line, .line, .line, .close], points: [
            ScenePoint(x: 0, y: 0), ScenePoint(x: 50.5, y: 0),
            ScenePoint(x: 50.5, y: 100), ScenePoint(x: 0, y: 100)
        ])
        let shapes: [SourceShape] = [
            .rectangle(reversed: false, size: ScenePoint(x: 60, y: 60),
                       position: ScenePoint(x: 50, y: 50), roundness: 0),
            .fill(color: SceneColor(red: 255, green: 0, blue: 0), opacity: 255),
            .fill(color: SceneColor(red: 0, green: 0, blue: 255), opacity: 255)
        ]
        let transform = SourceTransformProperties(constant: SourceTransform(anchor: .zero, position: .zero,
                                                                            scale: .one, rotation: 0, opacity: 128))
        let layer = SceneFixtures.layer(1, transform: transform, content: .shape(shapes),
                                        masks: [MaskTestSupport.mask(.init(constant: path), inverted: inverted)])
        let file = try SceneFixtures.build([SceneFixtures.composition(1, layers: [layer])])
        let scene = try await PreparedScene.prepare(file.composition)
        return try await FramePlanner.prepare(scene, at: .zero, targetSize: PAGSize(width: 100, height: 100),
                                              scale: 1, mode: .none)
    }

    /// 比对预乘RGBA8金值，每通道只容许Metal覆盖与量化产生一个整数差异。
    private func expect(_ actual: [SIMD4<UInt8>], near expected: [SIMD4<UInt8>]) throws {
        #expect(actual.count == expected.count)
        for (pixel, gold) in zip(actual, expected) {
            for channel in 0..<4 {
                #expect(abs(Int(pixel[channel]) - Int(gold[channel])) <= 1,
                        "实际\(pixel)，独立SrcOver金值\(gold)")
            }
        }
    }
}
#endif
