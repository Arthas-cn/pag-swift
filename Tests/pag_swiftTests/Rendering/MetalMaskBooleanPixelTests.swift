#if os(macOS)
import AppKit
import Metal
import Testing
@testable import pag_swift

/// 已挂载macOS drawable上直接核对同层多路径Boolean的真实片元覆盖，不启动demo。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct MetalMaskBooleanPixelTests {
    /// 四种Boolean及扩张经正式计划到挂载drawable核对，最终路径只接受一次AA。
    @MainActor @Test func orderedBooleanModesReachMountedDrawable() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 100, height: 100),
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
            let first = try rectangle(left: 0, right: 60.5)
            let second = try rectangle(left: 40.5, right: 100)
            let points = [20, 40, 50, 60, 80].map { SIMD2($0, 50) }
            for (mode, alphas): (SourceMaskMode, [UInt8]) in [
                (.add, [255, 255, 255, 255, 255]),
                (.subtract, [255, 128, 0, 0, 0]),
                (.intersect, [0, 128, 255, 128, 0]),
                (.difference, [255, 128, 0, 128, 255])
            ] {
                let expression = try SampledMaskExpression(terms: [
                    SampledMaskTerm(path: first, mode: .add, isInverted: false),
                    SampledMaskTerm(path: second, mode: mode, isInverted: false)
                ])
                let mask = FrameMask(layerID: try MetalGroupFixtures.layer, source: .expression(expression),
                                     isInverted: expression.isInverted, matrix: .identity)
                let solid = FrameSolid(layerID: try MetalGroupFixtures.layer,
                                       size: try PAGSize(width: 100, height: 100),
                                       color: SceneColor(red: 255, green: 0, blue: 0), matrix: .identity,
                                       opacity: 1)
                let frame = MetalGroupFixtures.frame([.beginMask(mask), .solid(solid), .endMask])
                let pixels = try await owner.pixels(frame, target: target, at: points)
                #expect(pixels.count == alphas.count)
                for (pixel, alpha) in zip(pixels, alphas) {
                    #expect(abs(Int(pixel.w) - Int(alpha)) <= 1, "模式\(mode)实测\(pixel)期望alpha\(alpha)")
                    #expect(abs(Int(pixel.x) - Int(alpha)) <= 1)
                    #expect(pixel.y == 0 && pixel.z == 0)
                }
            }
            // 第一项反向后与第二项Union，远场为真；有限网格表示左侧洞而非可见区域。
            let invertedExpression = try SampledMaskExpression(terms: [
                SampledMaskTerm(path: first, mode: .add, isInverted: true),
                SampledMaskTerm(path: second, mode: .add, isInverted: false)
            ])
            #expect(invertedExpression.isInverted)
            let inverseMask = FrameMask(layerID: try MetalGroupFixtures.layer,
                                        source: .expression(invertedExpression), isInverted: true,
                                        matrix: .identity)
            let inverseSolid = FrameSolid(layerID: try MetalGroupFixtures.layer,
                size: try PAGSize(width: 100, height: 100),
                color: SceneColor(red: 255, green: 0, blue: 0), matrix: .identity, opacity: 1)
            let inverseFrame = MetalGroupFixtures.frame([.beginMask(inverseMask),
                                                         .solid(inverseSolid), .endMask])
            let inversePixels = try await owner.pixels(inverseFrame, target: target, at: points)
            for (pixel, alpha) in zip(inversePixels, [UInt8(0), 128, 255, 255, 255]) {
                #expect(abs(Int(pixel.w) - Int(alpha)) <= 1)
                #expect(abs(Int(pixel.x) - Int(alpha)) <= 1)
            }
            // 手工作用域之外再经正式Scene→FramePlanner核对同一路径，防止纯值计划接线漏用新来源。
            let layer = SceneFixtures.layer(1,
                content: .solid(size: try PAGSize(width: 100, height: 100),
                                color: SceneColor(red: 255, green: 0, blue: 0)),
                masks: [MaskTestSupport.mask(.init(constant: first), mode: .add),
                        MaskTestSupport.mask(.init(constant: second), mode: .difference)])
            let file = try SceneFixtures.build([SceneFixtures.composition(1, layers: [layer])])
            let scene = try await PreparedScene.prepare(file.composition)
            let planned = try await FramePlanner.prepare(scene, at: .zero,
                targetSize: try PAGSize(width: 100, height: 100), scale: 1, mode: .none)
            #expect(planned.plan.commands.contains { if case .beginMask(let mask) = $0 {
                if case .expression = mask.source { return true }
            }; return false })
            let plannedPixels = try await owner.pixels(planned, target: target, at: points)
            for (pixel, alpha) in zip(plannedPixels, [UInt8(255), 128, 0, 128, 255]) {
                #expect(abs(Int(pixel.w) - Int(alpha)) <= 1)
            }
            let insetPath = try SourcePath(verbs: [.move, .line, .line, .line, .close], points: [
                ScenePoint(x: 10, y: 10), ScenePoint(x: 20, y: 10),
                ScenePoint(x: 20, y: 20), ScenePoint(x: 10, y: 20)
            ])
            let expansionPoints = [7, 9, 11, 15, 19, 21, 23].map { SIMD2($0, 15) }
            for (expansion, inverted, alphas): (Double, Bool, [UInt8]) in [
                (2, false, [0, 255, 255, 255, 255, 255, 0]),
                (-2, false, [0, 0, 0, 255, 0, 0, 0]),
                (2, true, [255, 0, 0, 0, 0, 0, 255])
            ] {
                let sourceMask = MaskTestSupport.mask(.init(constant: insetPath), inverted: inverted,
                                                      expansion: .init(constant: expansion))
                let expandedLayer = SceneFixtures.layer(1,
                    content: .solid(size: try PAGSize(width: 100, height: 100),
                                    color: SceneColor(red: 255, green: 0, blue: 0)),
                    masks: [sourceMask])
                let expandedFile = try SceneFixtures.build([SceneFixtures.composition(1, layers: [expandedLayer])])
                let expandedScene = try await PreparedScene.prepare(expandedFile.composition)
                let expandedPlan = try await FramePlanner.prepare(expandedScene, at: .zero,
                    targetSize: try PAGSize(width: 100, height: 100), scale: 1, mode: .none)
                let expandedPixels = try await owner.pixels(expandedPlan, target: target, at: expansionPoints)
                for (pixel, alpha) in zip(expandedPixels, alphas) {
                    #expect(abs(Int(pixel.w) - Int(alpha)) <= 1,
                            "扩张\(expansion)反向\(inverted)实测\(pixel)期望alpha\(alpha)")
                }
            }
            // 空Close先于后项仍占首项；反向空集减方形成为方形洞，不能当序列损坏。
            let closeOnly = try SourcePath(verbs: [.close, .close], points: [])
            let orderedMasks = [
                MaskTestSupport.mask(.init(constant: closeOnly), inverted: true,
                                     expansion: .init(constant: 2)),
                MaskTestSupport.mask(.init(constant: insetPath), mode: .subtract)
            ]
            let orderedLayer = SceneFixtures.layer(1,
                content: .solid(size: try PAGSize(width: 100, height: 100),
                                color: SceneColor(red: 255, green: 0, blue: 0)), masks: orderedMasks)
            let orderedFile = try SceneFixtures.build([SceneFixtures.composition(1, layers: [orderedLayer])])
            let orderedScene = try await PreparedScene.prepare(orderedFile.composition)
            let orderedPlan = try await FramePlanner.prepare(orderedScene, at: .zero,
                targetSize: try PAGSize(width: 100, height: 100), scale: 1, mode: .none)
            let orderedPixels = try await owner.pixels(orderedPlan, target: target,
                at: [SIMD2(5, 15), SIMD2(15, 15), SIMD2(25, 15)])
            for (pixel, alpha) in zip(orderedPixels, [UInt8(255), 0, 255]) {
                #expect(abs(Int(pixel.w) - Int(alpha)) <= 1)
            }
            // 扩张先作用于首源项，再参与同层Boolean；取交/相减必须读到真实描边轮廓。
            let rightPath = try SourcePath(verbs: [.move, .line, .line, .line, .close], points: [
                ScenePoint(x: 15, y: 10), ScenePoint(x: 25, y: 10),
                ScenePoint(x: 25, y: 20), ScenePoint(x: 15, y: 20)
            ])
            for (mode, alphas): (SourceMaskMode, [UInt8]) in [
                (.intersect, [0, 0, 255, 255, 0]),
                (.subtract, [255, 255, 0, 0, 0])
            ] {
                let masks = [MaskTestSupport.mask(.init(constant: insetPath),
                                                  expansion: .init(constant: 2)),
                             MaskTestSupport.mask(.init(constant: rightPath), mode: mode)]
                let layer = SceneFixtures.layer(1,
                    content: .solid(size: try PAGSize(width: 100, height: 100),
                                    color: SceneColor(red: 255, green: 0, blue: 0)), masks: masks)
                let file = try SceneFixtures.build([SceneFixtures.composition(1, layers: [layer])])
                let scene = try await PreparedScene.prepare(file.composition)
                let plan = try await FramePlanner.prepare(scene, at: .zero,
                    targetSize: try PAGSize(width: 100, height: 100), scale: 1, mode: .none)
                let pixels = try await owner.pixels(plan, target: target,
                    at: [9, 14, 17, 21, 24].map { SIMD2($0, 15) })
                for (pixel, alpha) in zip(pixels, alphas) {
                    #expect(abs(Int(pixel.w) - Int(alpha)) <= 1,
                            "扩张后模式\(mode)实测\(pixel)期望alpha\(alpha)")
                }
            }
            // 上游负hairline后仅接交集仍是零verb，正式计划须撤销裁剪而显示整张solid。
            let hairlineMasks = [
                MaskTestSupport.mask(.init(constant: insetPath),
                                     expansion: .init(constant: -1.0 / 8192)),
                MaskTestSupport.mask(.init(constant: rightPath), mode: .intersect)
            ]
            let hairlineLayer = SceneFixtures.layer(1,
                content: .solid(size: try PAGSize(width: 100, height: 100),
                                color: SceneColor(red: 255, green: 0, blue: 0)), masks: hairlineMasks)
            let hairlineFile = try SceneFixtures.build([SceneFixtures.composition(1, layers: [hairlineLayer])])
            let hairlineScene = try await PreparedScene.prepare(hairlineFile.composition)
            let hairlinePlan = try await FramePlanner.prepare(hairlineScene, at: .zero,
                targetSize: try PAGSize(width: 100, height: 100), scale: 1, mode: .none)
            #expect(!hairlinePlan.plan.commands.contains { if case .beginMask = $0 { return true }; return false })
            let hairlinePixels = try await owner.pixels(hairlinePlan, target: target,
                at: [SIMD2(5, 15), SIMD2(18, 15), SIMD2(30, 15)])
            for pixel in hairlinePixels { #expect(pixel == SIMD4<UInt8>(255, 0, 0, 255)) }
        } catch {
            await target.close()
            window.close()
            throw error
        }
        await target.close()
        window.close()
    }

    /// 构造具有真实半像素竖边的闭合源路径，避免用矩形包围盒代替Boolean。
    private func rectangle(left: Double, right: Double) throws -> SourcePath {
        try SourcePath(verbs: [.move, .line, .line, .line, .close], points: [
            ScenePoint(x: left, y: 0), ScenePoint(x: right, y: 0),
            ScenePoint(x: right, y: 100), ScenePoint(x: left, y: 100)
        ])
    }
}
#endif
