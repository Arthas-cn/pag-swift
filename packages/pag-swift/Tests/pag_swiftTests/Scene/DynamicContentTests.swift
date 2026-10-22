import Foundation
import Testing
@testable import pag_swift

/// 类型化 tag 内容、宿主 URL 回调与文字三种布局的真实场景编辑。
struct DynamicContentTests {
    /// URL 回调只替换命中的图片图层，其他两个索引及源文件保持原样。
    @Test func imageURLReplacesOnlyNamedSlot() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/ImageDecodeTest.pag"))
        var composition = file.composition
        let target = try #require(composition.layers.first { $0.name == "test.png" })
        let others = composition.layers.filter { $0.id != target.id }
        let originalTarget = try #require(composition.image(for: target.id))
        let imageURL = try PAGFixtures.rootURL().appending(path: "media/bear.gif")
        try await composition.apply(.hidden, forTag: "test.png")
        #expect(composition.layer(withID: target.id)?.isVisible == false)
        try await composition.apply(.imageURL(imageURL), forTag: "test.png") { url in
            try await PAGImage.load(from: url)
        }
        #expect(composition.layer(withID: target.id)?.isVisible == true)
        #expect(composition.image(for: target.id)?.kind == .animated)
        #expect(composition.image(for: target.id)?.storage !== originalTarget.storage)
        for layer in others {
            #expect(composition.image(for: layer.id)?.storage === file.composition.image(for: layer.id)?.storage)
        }
        #expect(file.composition.image(for: target.id)?.storage === originalTarget.storage)
    }

    /// 缺 URL 回调、tag 不存在和文字投向图片都报错，不留下半次编辑。
    @Test func invalidDynamicContentIsAtomic() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/ImageDecodeTest.pag"))
        var composition = file.composition
        let original = composition.edits.images
        let imageURL = try PAGFixtures.rootURL().appending(path: "media/bear.gif")
        await #expect(throws: PAGError.invalidArgument("loadImageFromURL")) {
            try await composition.apply(.imageURL(imageURL), forTag: "test.png")
        }
        await #expect(throws: PAGError.invalidArgument("dynamicContentKind")) {
            try await composition.apply(.text("错误", layout: .automatic), forTag: "test.png")
        }
        await #expect(throws: PAGError.invalidArgument("dynamicTag")) {
            try await composition.apply(.hidden, forTag: "不存在")
        }
        #expect(composition.edits.images.count == original.count)
    }

    /// 同一长文字可保留自动字号、截成省略号或保持原字号滚动，三者有实际准备结果。
    @Test func textLayoutsUseOneNamedSourceWithoutChangingFile() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        let tag = "text:0"
        let full = String(repeating: "PAG Swift ", count: 12)
        var automatic = file.composition
        try await automatic.apply(.text("", layout: .automatic), forTag: tag)
        #expect(automatic.layers.first?.isVisible == false)
        try await automatic.apply(.text(full, layout: .automatic), forTag: tag)
        #expect(automatic.layers.first?.isVisible == true)
        let autoScene = try await PreparedScene.prepare(automatic)
        #expect(try automatic.text(at: 0).text == full)
        #expect(autoScene.texts.values.first?.style.text == full)

        var truncated = file.composition
        try await truncated.apply(.text(full, layout: .truncate), forTag: tag)
        let truncatedScene = try await PreparedScene.prepare(truncated)
        let visible = try #require(truncatedScene.texts.values.first?.style.text)
        #expect(visible.hasSuffix("…") && visible.count < full.count)
        #expect(try truncated.text(at: 0).text == full)

        var marquee = file.composition
        let options = try PAGMarqueeOptions(speed: 45, gap: 24)
        try await marquee.apply(.text(full, layout: .marquee(options)), forTag: tag)
        let marqueeScene = try await PreparedScene.prepare(marquee)
        #expect(marqueeScene.texts.values.first?.style.text == full)
        #expect(marqueeScene.marqueeWidths.values.first ?? 0 > 187.5)
        #expect(try file.composition.text(at: 0).text == "04.这是一个字幕")
    }
}
