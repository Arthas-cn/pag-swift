#if os(macOS)
import Metal
import Testing
@testable import pag_swift

/// 可完整通过当前语义门禁的tag70真实文件从公开载入到生产Metal输入的闭环。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"))
struct MetalTextAnimatorFileTests {
    /// 八份真实tag70文件首中末帧均须可准备真实字形和文字背景。
    @Test(arguments: ["RangeSelectorTriangleEaseHighAndLow.pag", "TextAnimatorMode.pag",
        "TextAnimatorSmooth.pag", "TextPositionAnimator.pag", "TrackingAnimatorVertical.pag",
        "TextAnimators.pag", "TrackingAnimator.pag", "TextAnimatorX7.pag"])
    func realFileSelectedFramesPrepareForMetal(_ name: String) async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        let size = try PAGSize(width: 256, height: 256)
        var visibleGlyphFrames = 0
        var backgroundFrames = 0
        for index in Set([Int64(0), root.durationFrames / 2, root.durationFrames - 1]).sorted() {
            let frame = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: index, rate: root.frameRate),
                targetSize: size, scale: 1, mode: .stretch)
            if frame.texts.values.contains(where: { !$0.glyphs.isEmpty }) { visibleGlyphFrames += 1 }
            if name == "TextAnimators.pag" || name == "TrackingAnimator.pag" {
                for (commandIndex, command) in frame.plan.commands.enumerated() {
                    guard case .shape(let shape) = command,
                          case .text(let source) = file.storage.compositions[shape.geometryID.source.composition]
                              .layers[shape.geometryID.source.layer].content,
                          source.backgroundAlpha > 0 else { continue }
                    // 真实文字背景既要进入几何资源表，也必须排在同层字形轮次之前。
                    #expect(frame.shapes[shape.geometryID] != nil)
                    #expect(frame.plan.commands.dropFirst(commandIndex + 1).contains { following in
                        if case .text(let value) = following { return value.layerID == shape.layerID }
                        return false
                    })
                    backgroundFrames += 1
                }
            }
            let batch = try MetalFramePreparation.prepare(frame, width: 256, height: 256,
                resources: resources, disablePictureCache: true)
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
        #expect(visibleGlyphFrames > 0, "file=\(name)")
        if name == "TextAnimators.pag" || name == "TrackingAnimator.pag" {
            #expect(backgroundFrames > 0, "file=\(name)")
        }
    }
}
#endif
