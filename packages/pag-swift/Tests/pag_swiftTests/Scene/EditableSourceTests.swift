import Foundation
import Testing
@testable import pag_swift

/// 真实图片/文本源场景必须完整解码后，才验收公开编辑数据。
struct EditableSourceTests {
    /// TEXT04 的字体、填充、描边、行距必须来自真实源字段，不填空文本或默认样式。
    @Test func decodesRealText() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        #expect(file.composition.size == (try PAGSize(width: 188, height: 32)))
        #expect(file.composition.duration.microseconds == 30_000_000)
        #expect(file.composition.frameRate == 24)
        #expect(file.editableTextIndices == [0] && file.editableTextCount == 1)
        #expect(file.editableImageIndices.isEmpty)
        let text = try file.composition.text(at: 0)
        #expect(text.text == "04.这是一个字幕")
        #expect(text.fontFamily == "PingFang SC" && text.fontStyle == "Medium")
        #expect(text.fontSize == 24 && text.tracking == 0)
        // 源文件的 67 66 e6 41 比十进制 28.8 最近 Float32 高一格，必须保留源精度。
        #expect(text.leading == Double(Float(bitPattern: 0x41e66667)))
        #expect(text.strokeWidth == Double(Float(3.55)))
        #expect(text.fillColor == (try PAGColor(red: 1, green: 183.0 / 255, blue: 0)))
        #expect(text.strokeColor == (try PAGColor(red: 0, green: 0, blue: 0)))
        let layer = try #require(file.composition.layers.first)
        #expect(layer.kind == .text && layer.editableIndex == 0)
    }

    /// 图片槽沿编码顺序编号，公开层顺序相反；原始 WebP 都完整生成输入像素。
    @Test func decodesRealImageSlots() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/ImageDecodeTest.pag"))
        #expect(file.editableImageCount == 3 && file.editableImageIndices == [0, 1, 2])
        #expect(file.composition.layers.map(\.name) == ["test.png", "scene.png", "512-logo.png"])
        #expect(file.composition.layers.map(\.editableIndex) == [2, 1, 0])
        for layer in file.composition.layers {
            let image = try #require(file.composition.image(for: layer.id))
            #expect(image.kind == .still && image.duration == nil)
            #expect(image.storage.pixels.count == Int(image.size.width * image.size.height) * 4)
        }
    }

    /// V2 的源 scaleFactor 使逻辑尺寸大于编码像素，不能丢弃该比例。
    @Test func preservesEmbeddedImageScale() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/replace.pag"))
        let source = try #require(file.storage.resources.images[12])
        #expect(source.image.size == (try PAGSize(width: 666, height: 888)))
        #expect(source.logicalSize == (try PAGSize(width: 3027, height: 4036)))
        #expect(source.scaleFactor == Double(Float(0.22)))
        #expect(source.anchor == .zero)
        #expect(file.editableImageIndices == [0, 1])
    }

    /// 有文本不代表完整语义已支持；文本路径样例不能返回残缺可编辑文档。
    @Test(arguments: [("TextPathCommon.pag", "layerTag:14")])
    func unsupportedDependenciesFail(_ name: String, _ reason: String) async throws {
        await #expect(throws: PAGError.unsupportedFeature(reason)) {
            try await PAGLoader().load(data: PAGFixtures.data(named: name))
        }
    }
}
