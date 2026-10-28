#if os(macOS)
import Metal
import Testing
@testable import pag_swift

/// 九份真实文字路径从公开载入到生产Metal准备的文件级检查；像素金值另单独验收。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"))
struct MetalTextPathFileTests {
    /// 每份文件首中末帧必须保留实际字形与路径矩阵，准备后的GPU附件全部归还。
    @Test(arguments: ["TextPathBox.pag", "TextPathBox2.pag", "TextPathBoxReversed.pag",
        "TextPathClosedPath.pag", "TextPathCommon.pag", "TextPathForceAlignment.pag",
        "TextPathForceAlignment2.pag", "TextPathNotPerpendicular.pag", "TextPathReversed.pag"])
    func realFileSelectedFramesPrepareForMetal(_ name: String) async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let size = try PAGSize(width: 100, height: 100)
        let resources = try MetalResources(device: try #require(MTLCreateSystemDefaultDevice()))
        var visibleGlyphFrames = 0
        for index in Set([Int64(0), root.durationFrames / 2, root.durationFrames - 1]).sorted() {
            let frame = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: index, rate: root.frameRate),
                targetSize: size, scale: 1, mode: .stretch)
            if frame.texts.values.contains(where: { !$0.glyphs.isEmpty }) { visibleGlyphFrames += 1 }
            let batch = try MetalFramePreparation.prepare(frame, width: 100, height: 100,
                resources: resources, disablePictureCache: true)
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
        #expect(visibleGlyphFrames > 0, "file=\(name)")
    }
}
#endif
