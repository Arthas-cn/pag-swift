#if os(macOS)
import AppKit
import Metal
import QuartzCore
import Testing
@testable import pag_swift

/// Screen预合成必须先内部SrcOver、再把完整结果与既有背景混合。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalScreenBlendTests {
    /// 蓝背景上的红/绿重叠应出现青色而非逐子图元Screen得到的白色。
    @MainActor @Test func screenCompositesWholeGroupOnMountedDrawable() async throws {
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
            let size = try PAGSize(width: 20, height: 20)
            let commands: [FrameCommand] = [
                .solid(FrameSolid(layerID: layer, size: try PAGSize(width: 100, height: 100),
                    color: SceneColor(red: 0, green: 0, blue: 255), matrix: .identity, opacity: 1)),
                .beginGroup(FrameGroup(layerID: layer, frame: 0, clip: clip, opacity: 1,
                    application: .composite, blendMode: .screen)),
                .solid(FrameSolid(layerID: layer, size: size,
                    color: SceneColor(red: 255, green: 0, blue: 0),
                    matrix: try .translation(x: 10, y: 20), opacity: 1)),
                .solid(FrameSolid(layerID: layer, size: size,
                    color: SceneColor(red: 0, green: 255, blue: 0),
                    matrix: try .translation(x: 20, y: 20), opacity: 1)),
                .endGroup
            ]
            let frame = MetalGroupFixtures.frame(commands)
            let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
            let batch = try MetalFramePreparation.prepare(frame, width: 100, height: 100, resources: resources)
            #expect(batch.loans.count == 1 && batch.passes.count == 2)
            #expect(batch.passes.last?.draws.last?.screenBlend == true)
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
            let pixels = try await owner.pixels(frame, target: target,
                at: [SIMD2(15, 25), SIMD2(25, 25), SIMD2(35, 25), SIMD2(5, 5)])
            #expect(pixels == [SIMD4(255, 0, 255, 255), SIMD4(0, 255, 255, 255),
                               SIMD4(0, 255, 255, 255), SIMD4(0, 0, 255, 255)])
            var filtered = commands
            filtered[1] = .beginGroup(FrameGroup(layerID: layer, frame: 0, clip: clip, opacity: 1,
                application: .composite, blendMode: .screen, levelsGreenOnly: true))
            let greenPixels = try await owner.pixels(MetalGroupFixtures.frame(filtered), target: target,
                at: [SIMD2(15, 25), SIMD2(25, 25), SIMD2(35, 25), SIMD2(5, 5)])
            // tag57在整层合成后清除红蓝：红色独占区回到背景蓝，绿区仍与蓝Screen为青。
            #expect(greenPixels == [SIMD4(0, 0, 255, 255), SIMD4(0, 255, 255, 255),
                                    SIMD4(0, 255, 255, 255), SIMD4(0, 0, 255, 255)])
            let tile = try FrameMotionTile(SampledMotionTile(center: ScenePoint(x: 50, y: 50),
                tileWidth: 100, tileHeight: 100, outputWidth: 300, outputHeight: 300,
                mirrorEdges: true, phase: 0, horizontalPhaseShift: false),
                compositionSize: try PAGSize(width: 100, height: 100))
            filtered[1] = .beginGroup(FrameGroup(layerID: layer, frame: 0, clip: clip, opacity: 1,
                application: .composite, blendMode: .screen, levelsGreenOnly: true, motionTile: tile))
            let tileFrame = MetalGroupFixtures.frame(filtered)
            let tileBatch = try MetalFramePreparation.prepare(tileFrame, width: 100, height: 100,
                resources: resources)
            #expect(tileBatch.passes.last?.draws.last?.motionTile != nil)
            #expect(tileBatch.passes.last?.draws.last?.textBulgeMap != nil)
            tileBatch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
            let tilePixels = try await owner.pixels(tileFrame, target: target,
                at: [SIMD2(15, 25), SIMD2(25, 25), SIMD2(35, 25), SIMD2(5, 5)])
            #expect(tilePixels == greenPixels)
            let smallClip = FrameClip(size: try PAGSize(width: 40, height: 40), matrix: .identity)
            let smallTile = try FrameMotionTile(SampledMotionTile(center: ScenePoint(x: 20, y: 20),
                tileWidth: 100, tileHeight: 100, outputWidth: 300, outputHeight: 300,
                mirrorEdges: true, phase: 0, horizontalPhaseShift: false),
                compositionSize: smallClip.size)
            let repeated: [FrameCommand] = [commands[0],
                .beginGroup(FrameGroup(layerID: layer, frame: 0, clip: smallClip, opacity: 1,
                    application: .composite, blendMode: .screen, levelsGreenOnly: true, motionTile: smallTile)),
                .solid(FrameSolid(layerID: layer, size: try PAGSize(width: 20, height: 40),
                    color: SceneColor(red: 255, green: 0, blue: 0), matrix: .identity, opacity: 1)),
                .solid(FrameSolid(layerID: layer, size: try PAGSize(width: 20, height: 40),
                    color: SceneColor(red: 0, green: 255, blue: 0),
                    matrix: try .translation(x: 20, y: 0), opacity: 1)),
                .endGroup]
            let repeatedPixels = try await owner.pixels(MetalGroupFixtures.frame(repeated), target: target,
                at: [SIMD2(10, 20), SIMD2(30, 20), SIMD2(50, 20), SIMD2(70, 20)])
            // 第二块镜像：绿半块先于红半块出现，且红经Levels归零只留下蓝背景。
            #expect(repeatedPixels == [SIMD4(0, 0, 255, 255), SIMD4(0, 255, 255, 255),
                                       SIMD4(0, 255, 255, 255), SIMD4(0, 0, 255, 255)])
            let blur = try MotionBlurSampling(previous: .identity,
                current: SceneAffine.translation(x: 12, y: 0))
            var blurred = repeated
            blurred[1] = .beginGroup(FrameGroup(layerID: layer, frame: 1, clip: smallClip, opacity: 1,
                application: .composite, blendMode: .screen, levelsGreenOnly: true,
                motionTile: smallTile, motionBlur: blur))
            let blurredFrame = MetalGroupFixtures.frame(blurred)
            let blurredBatch = try MetalFramePreparation.prepare(blurredFrame, width: 100, height: 100,
                resources: resources)
            #expect(blurredBatch.passes.last?.draws.last?.motionBlur != nil)
            blurredBatch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
            let row = (0..<100).map { SIMD2($0, 20) }
            let plainRow = try await owner.pixels(MetalGroupFixtures.frame(repeated), target: target, at: row)
            let blurRow = try await owner.pixels(blurredFrame, target: target, at: row)
            // 平移速度跨越平铺边界，37采样应产生实际像素差分且仍直接落在已挂载drawable。
            #expect(zip(plainRow, blurRow).contains { $0.0 != $0.1 })
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
