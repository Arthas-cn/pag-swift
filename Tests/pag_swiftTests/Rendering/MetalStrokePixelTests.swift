#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 在真实显示drawable上核对描边像素；与生产RenderOwner生命周期测试共同构成显示门禁。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct MetalStrokePixelTests {
    /// 描边及无快照Shape/Text/旋转预合成的重叠结果由生产帧和真实drawable对照独立SrcOver金值。
    @MainActor @Test func verifiesStrokePixelsOnMountedDrawable() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · Stroke pixels"
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
            let cross = try await MetalStrokeFixtures.scene(MetalStrokeFixtures.crossing())
            let crossing = try await owner.pixels(ShapePathFixtures.plan(cross, at: 0), target: target,
                at: [SIMD2(25, 25), SIMD2(12, 25), SIMD2(12, 12)])
            expect(crossing, [SIMD4(128, 0, 0, 128), SIMD4(128, 0, 0, 128), .zero])

            let group = try await MetalStrokeFixtures.scene(MetalStrokeFixtures.mixedGroup())
            let grouped = try await owner.pixels(ShapePathFixtures.plan(group, at: 0), target: target,
                at: [SIMD2(16, 40), SIMD2(20, 40), SIMD2(40, 40), SIMD2(5, 5)])
            // 绿→红→蓝各继承a=128/255；红只被蓝覆盖一次为a(1-a)，绿被两次覆盖为a(1-a)²。
            expect(grouped, [SIMD4(128, 0, 0, 128), SIMD4(64, 32, 128, 224), SIMD4(0, 128, 0, 128), .zero])

            let clip = FrameClip(size: try PAGSize(width: 100, height: 100), matrix: .identity)
            let uncached: [FrameCommand] = [
                .beginGroup(FrameGroup(layerID: nil, frame: 0, clip: clip, opacity: 0.5, application: .perDraw)),
                try MetalGroupFixtures.solid(), try MetalGroupFixtures.solid(x: 20), .endGroup
            ]
            let points = [SIMD2(15, 25), SIMD2(25, 25), SIMD2(35, 25), SIMD2(5, 5)]
            let inherited = try await owner.pixels(MetalGroupFixtures.frame(uncached), target: target, at: points)
            // 两次不透明红色paint各乘0.5；重叠处为0.5+0.5×(1−0.5)=0.75。
            expect(inherited, [SIMD4(128, 0, 0, 128), SIMD4(191, 0, 0, 191),
                               SIMD4(128, 0, 0, 128), .zero])

            let nested: [FrameCommand] = [
                .beginGroup(FrameGroup(layerID: nil, frame: 0, clip: clip, opacity: 0.5, application: .perDraw))
            ] + uncached + [.endGroup]
            let nestedPixels = try await owner.pixels(MetalGroupFixtures.frame(nested), target: target, at: points)
            // 两层alpha先相乘到每个draw成为0.25，重叠结果为0.4375。
            expect(nestedPixels, [SIMD4(64, 0, 0, 64), SIMD4(112, 0, 0, 112),
                                  SIMD4(64, 0, 0, 64), .zero])

            let half = SourceTransformProperties(constant: SourceTransform(anchor: .zero, position: .zero,
                scale: .one, rotation: 0, opacity: 128))
            let first = SourceShape.group(StrokeShapeFixtures.transform(), [
                .rectangle(reversed: false, size: ScenePoint(x: 40, y: 40), position: ScenePoint(x: 30, y: 40), roundness: 0),
                .fill(color: SceneColor(red: 255, green: 0, blue: 0), opacity: 255)
            ])
            let second = SourceShape.group(StrokeShapeFixtures.transform(), [
                .rectangle(reversed: false, size: ScenePoint(x: 40, y: 40), position: ScenePoint(x: 50, y: 40), roundness: 0),
                .fill(color: SceneColor(red: 255, green: 0, blue: 0), opacity: 255)
            ])
            let shapeSource = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, transform: half,
                content: .shape([first, second]))])
            let shapeScene = try await PreparedScene.prepare(SceneFixtures.build([shapeSource]).composition)
            let shapeFrame = try await FramePlanner.prepare(shapeScene, at: .zero, targetSize: shapeSource.size,
                                                            scale: 1, mode: .none)
            expect(try await owner.pixels(shapeFrame, target: target, at: [SIMD2(20, 40), SIMD2(40, 40),
                SIMD2(60, 40), SIMD2(80, 40)]), [SIMD4(128, 0, 0, 128), SIMD4(192, 0, 0, 192),
                                                 SIMD4(128, 0, 0, 128), .zero])

            var style = try TextFixtures.source("HI").style
            style.fontSize = 40
            style.strokeWidth = 10
            style.strokeColor = try PAGColor(red: 1, green: 0, blue: 0)
            style.fillColor = try PAGColor(red: 1, green: 0, blue: 0)
            let textTransform = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
                position: ScenePoint(x: 25, y: 65), scale: .one, rotation: 0, opacity: 128))
            let textSource = try SceneFixtures.composition(2, layers: [SceneFixtures.layer(2, transform: textTransform,
                content: .text(try TextFixtures.source("HI", style: style)))])
            let textScene = try await PreparedScene.prepare(SceneFixtures.build([textSource]).composition)
            let textFrame = try await FramePlanner.prepare(textScene, at: .zero, targetSize: textSource.size,
                                                           scale: 1, mode: .none)
            // H、I各有填充与描边：x30/x60重叠两次得0.75，H填充内部x40仅一次得0.5。
            expect(try await owner.pixels(textFrame, target: target, at: [SIMD2(30, 45), SIMD2(40, 45),
                SIMD2(60, 45), SIMD2(10, 45)]), [SIMD4(192, 0, 0, 192), SIMD4(128, 0, 0, 128),
                                                  SIMD4(192, 0, 0, 192), .zero])

            style.text = "HH"
            // 40pt PingFang的字距换算后约为−29pt，使两H近同位；下方矩阵断言固定此前提。
            style.tracking = -725
            let overlapTextSource = try SceneFixtures.composition(5, layers: [SceneFixtures.layer(5,
                transform: textTransform, content: .text(try TextFixtures.source("HH", style: style)))])
            let overlapTextScene = try await PreparedScene.prepare(SceneFixtures.build([overlapTextSource]).composition)
            let overlapTextFrame = try await FramePlanner.prepare(overlapTextScene, at: .zero,
                targetSize: overlapTextSource.size, scale: 1, mode: .none)
            let glyphs = try #require(overlapTextFrame.texts.values.first?.glyphs)
            #expect(glyphs.count == 2 && abs(glyphs[1].matrix.tx - glyphs[0].matrix.tx) < 1)
            // 两个H的tracking使其近乎同位；x30受两字各自fill/stroke四次覆盖，alpha=1−(1−a)^4。
            expect(try await owner.pixels(overlapTextFrame, target: target,
                at: [SIMD2(30, 45), SIMD2(40, 45), SIMD2(20, 45)]),
                [SIMD4(239, 0, 0, 239), SIMD4(192, 0, 0, 192), .zero])

            let rotated = try MetalGroupFixtures.rotatedUncachedComposition()
            let rotatedScene = try await PreparedScene.prepare(rotated)
            let rotatedFrame = try await FramePlanner.prepare(rotatedScene, at: .zero, targetSize: rotated.size,
                                                               scale: 1, mode: .none)
            let plain = try #require(rotatedFrame.plan.commands.compactMap { command -> FrameSolid? in
                if case .solid(let value) = command, value.layerID.path.last == 1 { value } else { nil }
            }.first)
            let overlap = try plain.matrix.applying(to: ScenePoint(x: 30, y: 20))
            let separate = try plain.matrix.applying(to: ScenePoint(x: 5, y: 20))
            let clipped = try plain.matrix.applying(to: ScenePoint(x: 50, y: 20))
            let leafClip = try #require(rotatedFrame.plan.commands.compactMap { command -> FrameGroup? in
                if case .beginGroup(let value) = command { value } else { nil }
            }.last).clip
            let corners = try [ScenePoint.zero, ScenePoint(x: 40, y: 0), ScenePoint(x: 40, y: 40),
                ScenePoint(x: 0, y: 40)].map { try leafClip.matrix.applying(to: $0) }
            // x50在叶合成局部clip外，却仍落在旋转后的包围盒里；只取AABB会错误画出第二层。
            let minX = try #require(corners.map(\.x).min()), maxX = try #require(corners.map(\.x).max())
            let minY = try #require(corners.map(\.y).min()), maxY = try #require(corners.map(\.y).max())
            #expect(clipped.x > minX && clipped.x < maxX)
            #expect(clipped.y > minY && clipped.y < maxY)
            let rotatedPoints = [overlap, separate, clipped].map { SIMD2(Int($0.x.rounded(.down)), Int($0.y.rounded(.down))) }
            // 两层128/255先乘到各draw；重叠为2a−a²≈112/255，单独覆盖为a≈64/255。
            expect(try await owner.pixels(rotatedFrame, target: target, at: rotatedPoints),
                   [SIMD4(112, 0, 0, 112), SIMD4(64, 0, 0, 64), .zero])

            let color = try await MetalStrokeFixtures.scene(MetalStrokeFixtures.animatedColor())
            for frame: Int64 in [0, 10, 0] {
                let pixels = try await owner.pixels(ShapePathFixtures.plan(color, at: frame), target: target, at: [SIMD2(25, 25)])
                expect(pixels, [frame == 10 ? SIMD4(0, 0, 255, 255) : SIMD4(128, 0, 0, 128)])
            }
            let width = try await MetalStrokeFixtures.scene(MetalStrokeFixtures.animatedWidth())
            for frame: Int64 in [0, 10, 0] {
                let pixels = try await owner.pixels(ShapePathFixtures.plan(width, at: frame), target: target, at: [SIMD2(16, 16)])
                expect(pixels, [frame == 10 ? SIMD4(128, 0, 0, 128) : .zero])
            }
            #expect(!target.mailbox.snapshot.hasLease)
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// 预乘通道由几何位置和源颜色手算，仅允许一次RGBA8存储量化误差。
    private func expect(_ actual: [SIMD4<UInt8>], _ expected: [SIMD4<UInt8>]) {
        #expect(actual.count == expected.count)
        for (a, b) in zip(actual, expected) {
            for channel in 0..<4 { #expect(abs(Int(a[channel]) - Int(b[channel])) <= 1, "RGBA实际\(a)，期望\(b)") }
        }
    }
}
#endif
