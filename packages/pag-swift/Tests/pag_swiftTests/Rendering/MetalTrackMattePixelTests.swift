#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 轨道遮罩无引用、空源及真实双输入效果均经过正式帧计划和已挂载drawable核对。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"),
       .serialized, .timeLimit(.minutes(1)))
struct MetalTrackMattePixelTests {
    /// 首层Alpha模式没有前驱，仍应显示原红色像素，而非被空遮罩抹掉。
    @MainActor @Test func firstLayerWithoutSourceDrawsOriginalColor() async throws {
        let size = try PAGSize(width: 100, height: 100)
        let source = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(1, trackMatte: .alpha,
                                content: .solid(size: size, color: SceneColor(red: 255, green: 0, blue: 0)))
        ])
        let file = try SceneFixtures.build([source])
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: size, scale: 1, mode: .none)
        let actual = try await pixels(frame, at: [SIMD2(50, 50), SIMD2(99, 99)])
        #expect(actual == [SIMD4(255, 0, 0, 255), SIMD4(255, 0, 0, 255)])
    }

    /// 邻层引用存在但源尚未开始时，正向遮罩应留下透明目标，反向遮罩应显示拥有者蓝色。
    @MainActor @Test func emptyReferencedSourceRespectsInversionOnDrawable() async throws {
        let size = try PAGSize(width: 100, height: 100)
        for (mode, expected) in [(SourceTrackMatteType.alpha, SIMD4<UInt8>(0, 0, 0, 0)),
                                 (.alphaInverted, SIMD4<UInt8>(0, 0, 255, 255))] {
            let source = try SceneFixtures.composition(1, layers: [
                SceneFixtures.layer(1, start: 10, duration: 5,
                                    content: .solid(size: size, color: SceneColor(red: 255, green: 0, blue: 0))),
                SceneFixtures.layer(2, trackMatte: mode,
                                    content: .solid(size: size, color: SceneColor(red: 0, green: 0, blue: 255)))
            ])
            let file = try SceneFixtures.build([source])
            let scene = try await PreparedScene.prepare(file.composition)
            let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: size, scale: 1, mode: .none)
            let actual = try await pixels(frame, at: [SIMD2(50, 50)])
            #expect(actual == [expected], "mode=\(mode.rawValue), actual=\(actual), expected=\(expected)")
        }
    }

    /// inactive绿源覆盖左半幅时，四种邻层模式按源alpha或亮度及反向在真实drawable显色。
    @MainActor @Test func referencedSourceCompositesAlphaAndLumaOnDrawable() async throws {
        let size = try PAGSize(width: 100, height: 100)
        let half = try PAGSize(width: 50, height: 100)
        for (mode, left, right) in [
            (SourceTrackMatteType.alpha, SIMD4<UInt8>(0, 0, 255, 255), SIMD4<UInt8>(0, 0, 0, 0)),
            (.alphaInverted, SIMD4<UInt8>(0, 0, 0, 0), SIMD4<UInt8>(0, 0, 255, 255)),
            (.luma, SIMD4<UInt8>(0, 0, 182, 182), SIMD4<UInt8>(0, 0, 0, 0)),
            (.lumaInverted, SIMD4<UInt8>(0, 0, 73, 73), SIMD4<UInt8>(0, 0, 255, 255))
        ] {
            let source = try SceneFixtures.composition(1, layers: [
                SceneFixtures.layer(1, active: false,
                    content: .solid(size: half, color: SceneColor(red: 0, green: 255, blue: 0))),
                SceneFixtures.layer(2, trackMatte: mode,
                    content: .solid(size: size, color: SceneColor(red: 0, green: 0, blue: 255)))
            ])
            let file = try SceneFixtures.build([source])
            let scene = try await PreparedScene.prepare(file.composition)
            let frame = try await FramePlanner.prepare(scene, at: .zero,
                targetSize: size, scale: 1, mode: .none)
            let actual = try await pixels(frame, at: [SIMD2(25, 50), SIMD2(75, 50)])
            for (pixel, expected) in zip(actual, [left, right]) {
                #expect(abs(Int(pixel.x) - Int(expected.x)) <= 1)
                #expect(abs(Int(pixel.y) - Int(expected.y)) <= 1)
                #expect(abs(Int(pixel.z) - Int(expected.z)) <= 1)
                #expect(abs(Int(pixel.w) - Int(expected.w)) <= 1)
            }
        }
    }

    /// 源自身半透明进入alpha和亮度因子，拥有者透明度不反向传给源图形。
    @MainActor @Test func sourceOpacityParticipatesInBothModes() async throws {
        let size = try PAGSize(width: 100, height: 100)
        let halfOpacity = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: .zero, scale: .one, rotation: 0, opacity: 128))
        for (mode, expected) in [(SourceTrackMatteType.alpha, 128), (.luma, 91)] {
            let source = try SceneFixtures.composition(1, layers: [
                SceneFixtures.layer(1, active: false, transform: halfOpacity,
                    content: .solid(size: size, color: SceneColor(red: 0, green: 255, blue: 0))),
                SceneFixtures.layer(2, trackMatte: mode,
                    content: .solid(size: size, color: SceneColor(red: 0, green: 0, blue: 255)))
            ])
            let file = try SceneFixtures.build([source])
            let scene = try await PreparedScene.prepare(file.composition)
            let frame = try await FramePlanner.prepare(scene, at: .zero,
                targetSize: size, scale: 1, mode: .none)
            let value = try #require(try await pixels(frame, at: [SIMD2(50, 50)]).first)
            #expect(value.x == 0 && value.y == 0)
            #expect(abs(Int(value.z) - expected) <= 1)
            #expect(abs(Int(value.w) - expected) <= 1)
        }
    }

    /// Shape源的真实路径覆盖及其可选Picture标记，进入局部遮罩后只留下左半幅拥有者。
    @MainActor @Test func shapeSourceUsesItsFilledGeometry() async throws {
        let size = try PAGSize(width: 100, height: 100)
        let white = SceneColor(red: 255, green: 255, blue: 255)
        let blue = SceneColor(red: 0, green: 0, blue: 255)
        let shape: [SourceShape] = [
            .rectangle(reversed: false, size: ScenePoint(x: 50, y: 100),
                       position: ScenePoint(x: 25, y: 50), roundness: 0),
            .fill(color: white, opacity: 255)
        ]
        let source = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(1, active: false, content: .shape(shape)),
            SceneFixtures.layer(2, trackMatte: .alpha, content: .solid(size: size, color: blue))
        ])
        let file = try SceneFixtures.build([source])
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: size, scale: 1, mode: .none)
        let actual = try await pixels(frame, at: [SIMD2(25, 50), SIMD2(75, 50)])
        #expect(actual == [SIMD4(0, 0, 255, 255), .zero])
    }

    /// 源时间和变换可见却无实际Shape图元时，正向遮空、反向保留完整拥有者。
    @MainActor @Test func emptySourceGeometryRespectsInversion() async throws {
        let size = try PAGSize(width: 100, height: 100)
        for (mode, expected) in [(SourceTrackMatteType.alpha, SIMD4<UInt8>.zero),
                                 (.alphaInverted, SIMD4<UInt8>(0, 0, 255, 255))] {
            let source = try SceneFixtures.composition(1, layers: [
                SceneFixtures.layer(1, active: false, content: .shape([])),
                SceneFixtures.layer(2, trackMatte: mode,
                    content: .solid(size: size, color: SceneColor(red: 0, green: 0, blue: 255)))
            ])
            let file = try SceneFixtures.build([source])
            let scene = try await PreparedScene.prepare(file.composition)
            let frame = try await FramePlanner.prepare(scene, at: .zero,
                targetSize: size, scale: 1, mode: .none)
            let actual = try await pixels(frame, at: [SIMD2(50, 50)])
            #expect(actual == [expected])
        }
    }

    /// inactive预合成源须展开自身子层，而不是把外层拥有者的变换或可见性传给它。
    @MainActor @Test func precompositionSourceExpandsItsChildren() async throws {
        let size = try PAGSize(width: 100, height: 100)
        let half = try PAGSize(width: 50, height: 100)
        let child = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(10, content: .solid(size: half,
                color: SceneColor(red: 255, green: 255, blue: 255)))
        ])
        let parent = try SceneFixtures.composition(2, layers: [
            SceneFixtures.layer(20, active: false, content: .precomposition(id: 1, startFrame: 0)),
            SceneFixtures.layer(21, trackMatte: .alpha,
                content: .solid(size: size, color: SceneColor(red: 0, green: 0, blue: 255)))
        ])
        let file = try SceneFixtures.build([child, parent])
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: size, scale: 1, mode: .none)
        let actual = try await pixels(frame, at: [SIMD2(25, 50), SIMD2(75, 50)])
        #expect(actual == [SIMD4(0, 0, 255, 255), .zero])
    }

    /// 真实list/7每个源帧都应从公开Loader进入完整Metal输入准备，且逐帧归还效果附件。
    @Test func realReferencedFilePreparesEveryFrame() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "list/7.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let target = try PAGSize(width: 100, height: 100)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        var referenceFrames = 0
        for index in 0..<root.durationFrames {
            let frame = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: index, rate: root.frameRate),
                targetSize: target, scale: 1, mode: .none)
            if frame.plan.commands.contains(where: { if case .beginTrackMatte = $0 { true } else { false } }) {
                referenceFrames += 1
            }
            let batch: MetalFrameBatch
            do {
                batch = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
                    resources: resources, disablePictureCache: true)
            } catch {
                let scopes = frame.plan.commands.enumerated().compactMap { offset, command -> String? in
                    switch command {
                    case .beginTrackMatte: return "\(offset):beginTrackMatte"
                    case .endTrackMatteSource: return "\(offset):endTrackMatteSource"
                    case .endTrackMatte: return "\(offset):endTrackMatte"
                    case .beginMask: return "\(offset):beginMask"
                    case .endMask: return "\(offset):endMask"
                    default: return nil
                    }
                }
                Issue.record("list/7源帧\(index)的Metal准备失败：\(error)")
                print("PAG_TRACK_MATTE_SCOPES \(scopes)")
                throw error
            }
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
        #expect(referenceFrames > 0)
    }

    /// 第二张局部附件借用或准备触及预算时，先借内容与所有子批次必须立即归零。
    @Test func tightBudgetReleasesPartialTrackMatteLoans() async throws {
        let size = try PAGSize(width: 100, height: 100)
        let source = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(1, active: false,
                content: .solid(size: size, color: SceneColor(red: 255, green: 255, blue: 255))),
            SceneFixtures.layer(2, trackMatte: .alpha,
                content: .solid(size: size, color: SceneColor(red: 0, green: 0, blue: 255)))
        ])
        let file = try SceneFixtures.build([source])
        let scene = try await PreparedScene.prepare(file.composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero,
            targetSize: size, scale: 1, mode: .none)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            _ = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
                resources: resources, maximumBytes: 55_000)
            Issue.record("两张100×100局部附件不得在55KB预算下全部成功")
        } catch PAGError.resourceLimitExceeded {
            #expect(resources.groups.activeBytes == 0)
        }
    }

    /// 真实list/7第120帧应把邻层轨道遮罩与祖先普通蒙版一起提交到挂载drawable。
    @MainActor @Test func realReferencedFileRendersMountedDrawable() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "list/7.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let size = try PAGSize(width: 100, height: 100)
        let frame = try await FramePlanner.prepare(scene,
            at: SceneValidator.time(frame: 120, rate: root.frameRate),
            targetSize: size, scale: 1, mode: .stretch)
        let points = (0..<4).flatMap { row in (0..<4).map { column in
            SIMD2<Int>(12 + column * 25, 12 + row * 25)
        } }
        let actual = try await pixels(frame, at: points)
        #expect(actual[0] == .zero)
        #expect(actual[3] == .zero)
        let reference = SIMD4<Int>(62, 190, 235, 255)
        let color = actual[9]
        #expect(abs(Int(color.x) - reference.x) <= 3)
        #expect(abs(Int(color.y) - reference.y) <= 3)
        #expect(abs(Int(color.z) - reference.z) <= 3)
        #expect(abs(Int(color.w) - reference.w) <= 3)
    }

    /// 诊断从生产租约下的drawable读点；窗口与GPU目标在测试结束时一并关闭。
    @MainActor private func pixels(_ frame: PreparedFrame,
                                   at points: [SIMD2<Int>]) async throws -> [SIMD4<UInt8>] {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · Track Matte no reference"
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
            let result = try await owner.pixels(frame, target: target, at: points)
            await target.close()
            window.close()
            return result
        } catch {
            await target.close()
            window.close()
            throw error
        }
    }
}
#endif
