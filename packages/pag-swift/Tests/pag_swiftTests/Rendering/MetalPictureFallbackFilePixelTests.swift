#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 真实PAG的无快照外层alpha金值；窗口drawable仅在测试中读取少量像素。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct MetalPictureFallbackFilePixelTests {
    /// TextDirection同层Star fill与stroke在外层127/255 alpha下，应按两次draw叠加，内部与空白点分别保持单次和零覆盖。
    @MainActor @Test func textDirectionStarUsesPerDrawOuterAlpha() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 360, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "pag-swift · Picture fallback file pixels"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 640))
        view.wantsLayer = true
        window.contentView = view
        let target = MetalStrokePixelTarget(width: 360, height: 640, scale: 4)
        let owner = MetalStrokePixelOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        do {
            let mutation = try #require(target.mailbox.beginMutation())
            try await owner.configure(target, mutation: mutation)
            try target.mount(to: #require(view.layer), mutation: mutation)
            #expect(target.mailbox.finishMutation(mutation, configuration: DisplayTargetConfiguration(
                geometry: try DisplayGeometry(size: PAGSize(width: 360, height: 640), scale: 4),
                isMounted: true, isActive: true)))
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()

            let file = try await PAGLoader().load(data: PAGFixtures.data(named: "TextDirection.pag"))
            let scene = try await PreparedScene.prepare(file.composition)
            let frame = try await FramePlanner.prepare(scene, at: PAGTime(microseconds: 2_000_000),
                targetSize: try PAGSize(width: 360, height: 640), scale: 4, mode: .aspectFit)
            let starGroups = frame.plan.commands.compactMap { command -> FrameOpacityGroup? in
                if case .beginOpacityGroup(let group) = command, group.layerID.path == [63] { group } else { nil }
            }
            #expect(starGroups.count == 1)
            #expect(starGroups.first?.application == .perDraw)
            #expect(starGroups.first?.opacity == Double(127) / 255)
            let rootGroup = try #require(frame.plan.commands.compactMap { command -> FrameGroup? in
                if case .beginGroup(let group) = command, group.layerID == nil { group } else { nil }
            }.first)
            let starGroup = try #require(starGroups.first)
            let starPaints = frame.plan.commands.compactMap { command -> FrameShape? in
                if case .shape(let paint) = command, paint.layerID.path == [63] { paint } else { nil }
            }
            #expect(starPaints.count == 2)
            // 正式文件的文字会盖住Star的细描边；这里只隔离同一文件的原始Star组，保留其生产几何、颜色与alpha。
            let starCommands: [FrameCommand] = [.beginGroup(rootGroup), .beginOpacityGroup(starGroup)] +
                starPaints.map { .shape($0) } + [.endOpacityGroup, .endGroup]
            let isolated = PreparedFrame(plan: FramePlan(time: frame.plan.time,
                targetBounds: frame.plan.targetBounds, commands: starCommands),
                images: [:], shapes: frame.shapes, texts: [:])

            // 原始Star中心在(382,694)；2倍根像素后，(260,700)只中fill，边P4→P5内侧(210,672)同时中fill与3pt stroke。
            let points = [SIMD2(520, 1400), SIMD2(420, 1344), SIMD2(200, 200)]
            let actual = try await owner.pixels(isolated, target: target, at: points)
            // 源RGBA为fill(159,130,244)、stroke(0,55,211)、共同a=127/255；手算SrcOver后量化到RGBA8。
            let expected = [SIMD4<UInt8>(79, 65, 122, 127), SIMD4<UInt8>(40, 60, 166, 191), .zero]
            #expect(actual.count == expected.count)
            for (pixel, gold) in zip(actual, expected) {
                for channel in 0..<4 {
                    #expect(abs(Int(pixel[channel]) - Int(gold[channel])) <= 1,
                            "真实TextDirection像素\(pixel)，独立金值\(gold)")
                }
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
}
#endif
