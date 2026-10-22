#if os(macOS)
import AppKit
import Foundation
import Metal
import QuartzCore
import Testing
@testable import pag_swift

/// 真实零尺寸投影文件从公开载入到局部源批次与根drawable绘制顺序。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .serialized)
struct MetalDropShadowFileTests {
    /// 六条纯位移投影须先于原图进入根pass，局部源只组合一次且借用可全部归还。
    @Test func realDistanceOnlyFilePreparesMetal() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "DropShadow.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        for index in Set([Int64(0), root.durationFrames / 2, root.durationFrames - 1]).sorted() {
            let frame = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: index, rate: root.frameRate),
                targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
            #expect(frame.plan.commands.contains {
                if case .beginDropShadow = $0 { return true }; return false
            })
            if ProcessInfo.processInfo.environment["PAG_SHADOW_PLAN_AUDIT"] == "1" {
                for (position, command) in frame.plan.commands.enumerated() {
                    switch command {
                    case .beginGroup, .endGroup, .beginMask, .endMask,
                         .beginTrackMatte, .endTrackMatteSource, .endTrackMatte,
                         .beginDropShadow, .endDropShadow:
                        print("PAG_SHADOW_PLAN \(position) \(command)")
                    default: break
                    }
                }
            }
            let batch = try MetalFramePreparation.prepare(frame, width: 256, height: 256,
                resources: resources, disablePictureCache: true)
            #expect(!batch.dropShadowWorks.isEmpty)
            #expect(batch.passes.last?.attachment == nil)
            #expect(batch.passes.last?.draws.contains(where: \.isShadow) == true)
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
    }

    /// 同一真实文件在已挂载drawable绘制时，开启投影须产生无投影原图没有的可见像素。
    @MainActor @Test func realDistanceOnlyShadowChangesMountedDrawable() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 256, height: 256),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · DropShadow"
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
            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "DropShadow.pag"))
            let scene = try await PreparedScene.prepare(file.composition)
            let frame = try await FramePlanner.prepare(scene, at: .zero,
                targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
            // 只从测试计划去掉样式边界，源图、遮罩和其它绘制保持相同，以核对投影的实际增量。
            let plain = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                targetBounds: frame.plan.targetBounds,
                commands: frame.plan.commands.filter {
                    switch $0 {
                    case .beginDropShadow, .endDropShadow: false
                    default: true
                    }
                }), images: frame.images, shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
            let points = (0..<64).flatMap { row in (0..<64).map { column in
                SIMD2<Int>(2 + column * 4, 2 + row * 4)
            } }
            let withShadow = try await owner.pixels(frame, target: target, at: points)
            let withoutShadow = try await owner.pixels(plain, target: target, at: points)
            #expect(zip(withShadow, withoutShadow).contains { $0.0.w > 0 && $0.1.w == 0 })
            await target.close()
            window.close()
        } catch {
            await target.close()
            window.close()
            throw error
        }
    }

    /// 真实正尺寸样式在已挂载drawable的原有不透明背景上产生连续软边色阶。
    @MainActor @Test func realGaussianShadowHasSoftEdgeOnMountedDrawable() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 256, height: 256),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · GaussianShadow"
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
            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "marker.pag"))
            let scene = try await PreparedScene.prepare(file.composition)
            let frame = try await FramePlanner.prepare(scene, at: .zero,
                targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
            let plain = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                targetBounds: frame.plan.targetBounds,
                commands: frame.plan.commands.filter {
                    switch $0 {
                    case .beginDropShadow, .endDropShadow: false
                    default: true
                    }
                }), images: frame.images, shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
            let points = (0..<64).flatMap { row in (0..<64).map { column in
                SIMD2<Int>(2 + column * 4, 2 + row * 4)
            } }
            let shadow = try await owner.pixels(frame, target: target, at: points)
            let original = try await owner.pixels(plain, target: target, at: points)
            // marker原画已有不透明背景，投影软边体现在同一像素的RGB增量而非最终alpha。
            let deltas = zip(shadow, original).map { abs(Int($0.0.x) - Int($0.1.x)) }
            #expect(deltas.filter { $0 > 0 }.count > 100)
            #expect(deltas.contains { (1...10).contains($0) })
            #expect(deltas.contains { $0 > 50 })
            await target.close()
            window.close()
        } catch {
            await target.close()
            window.close()
            throw error
        }
    }

    /// spread一用源alpha的椭圆采样产生蓝色二值扩散，原红图仍覆盖中心且外圈透明。
    @MainActor @Test func strokeSpreadColorsMountedDrawableWithoutOffscreenFrame() async throws {
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
            let style = SourceDropShadow(blendMode: 0, color: SceneColor(red: 0, green: 0, blue: 255),
                opacity: 255, angle: 180, distance: 0, size: 4, spread: 1)
            let transform = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
                position: ScenePoint(x: 40, y: 40), scale: .one, rotation: 0, opacity: 255))
            let layer = SourceLayer(id: 1, name: "stroke", parentID: nil,
                startFrame: 0, durationFrames: 30, isActive: true, transform: transform,
                content: .solid(size: try PAGSize(width: 20, height: 20),
                                color: SceneColor(red: 255, green: 0, blue: 0)),
                dropShadows: [style])
            let file = try SceneFixtures.build([SceneFixtures.composition(1, layers: [layer])])
            let scene = try await PreparedScene.prepare(file.composition)
            let frame = try await FramePlanner.prepare(scene, at: .zero,
                targetSize: try PAGSize(width: 100, height: 100), scale: 1, mode: .none)
            let actual = try await owner.pixels(frame, target: target,
                at: [SIMD2(35, 50), SIMD2(38, 50), SIMD2(40, 50), SIMD2(50, 50), SIMD2(61, 50)])
            #expect(actual[0] == .zero)
            #expect(actual[1].z > 200 && actual[1].w > 200)
            #expect(actual[2].x > 200 && actual[2].z < 10)
            #expect(actual[3].x > 200 && actual[3].z < 10)
            #expect(actual[4].z > 200 && actual[4].w > 200)
            await target.close()
            window.close()
        } catch {
            await target.close()
            window.close()
            throw error
        }
    }

    /// V2中间spread须在同一挂载drawable先形成二值扩散、再出现Gaussian软边，源图仍盖住阴影。
    @MainActor @Test func intermediateSpreadCombinesStrokeAndGaussianOnMountedDrawable() async throws {
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
            let transform = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
                position: ScenePoint(x: 40, y: 40), scale: .one, rotation: 0, opacity: 255))
            var samples: [[SIMD4<UInt8>]] = []
            for spread in [0.5, 1.0] {
                let style = SourceDropShadow(blendMode: 0,
                    color: SceneColor(red: 0, green: 0, blue: 255), opacity: 255,
                    angle: 180, distance: 0, size: 8, spread: spread)
                let layer = SourceLayer(id: 1, name: "stroke+blur", parentID: nil,
                    startFrame: 0, durationFrames: 30, isActive: true, transform: transform,
                    content: .solid(size: try PAGSize(width: 20, height: 20),
                                    color: SceneColor(red: 255, green: 0, blue: 0)),
                    dropShadows: [style])
                let file = try SceneFixtures.build([SceneFixtures.composition(1, layers: [layer])])
                let scene = try await PreparedScene.prepare(file.composition)
                let frame = try await FramePlanner.prepare(scene, at: .zero,
                    targetSize: try PAGSize(width: 100, height: 100), scale: 1, mode: .none)
                samples.append(try await owner.pixels(frame, target: target,
                    at: [SIMD2(30, 50), SIMD2(33, 50), SIMD2(35, 50),
                         SIMD2(38, 50), SIMD2(50, 50)]))
            }
            let mixed = try #require(samples.first)
            let expanded = try #require(samples.last)
            #expect(mixed[0] == .zero)
            #expect(mixed[1].w > 0 && mixed[1].w < mixed[2].w)
            #expect(mixed[2].w < mixed[3].w && mixed[2].z > 0)
            #expect(expanded[2].w > mixed[2].w)
            #expect(mixed[4].x > 200 && mixed[4].z < 10)
            await target.close()
            window.close()
        } catch {
            await target.close()
            window.close()
            throw error
        }
    }

    /// 真实V2嵌套扩散及手势等距旋转Gaussian在同一挂载drawable分别产生可见差异。
    @MainActor @Test func realSpreadAndRotatedGaussianChangeMountedDrawable() async throws {
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
            let points = (0..<64).flatMap { row in (0..<64).map { column in
                SIMD2<Int>(2 + column * 4, 2 + row * 4)
            } }
            for (name, time) in [("zongyi2.pag", Int64(0)), ("guide_hand_drag.pag", Int64(500_000))] {
                let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
                let scene = try await PreparedScene.prepare(file.composition)
                let frame = try await FramePlanner.prepare(scene, at: PAGTime(microseconds: time),
                    targetSize: try PAGSize(width: 256, height: 256), scale: 1, mode: .aspectFit)
                // 只去掉样式边界而不改源内容，差异才来自当前文件的真实投影。
                let plain = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                    targetBounds: frame.plan.targetBounds, commands: frame.plan.commands.filter {
                        switch $0 {
                        case .beginDropShadow, .endDropShadow: false
                        default: true
                        }
                    }), images: frame.images, shapes: frame.shapes, texts: frame.texts, videos: frame.videos)
                let withShadow = try await owner.pixels(frame, target: target, at: points)
                let withoutShadow = try await owner.pixels(plain, target: target, at: points)
                #expect(zip(withShadow, withoutShadow).filter { $0.0 != $0.1 }.count > 10,
                    "file=\(name)")
            }
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
