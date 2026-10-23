import Testing
@testable import pag_swift

/// 业务源槽目录覆盖嵌套、名称碰撞和共享实例，编辑仍保持值语义。
struct ContentSlotTests {
    /// 嵌套合成重复引用只产生四个源槽；跨类型同名和同源多名使用派生 tag。
    @Test func nestedSourcesAreDeduplicated() async throws {
        let file = try await EditableFixtures.file()
        let slots = file.contentSlots
        #expect(slots.map(\.tag) == ["text:0", "text:1", "image:0", "image:1"])
        #expect(slots.map(\.instanceCount) == [2, 1, 1, 4])
        #expect(slots.last?.sourceNames == ["other", "shared"])
        #expect(slots.last?.size == file.storage.resources.images[12]?.logicalSize)
        #expect(slots == file.composition.contentSlots)
    }

    /// 真实名称占用派生键及后缀时所有槽仍可达，且查询结果稳定。
    @Test func realNamesCannotShadowDerivedTags() async throws {
        let input = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        let text = try #require(input.storage.catalog.texts.first)
        let root = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(1, name: "", content: .text(text)),
            SceneFixtures.layer(2, name: "text:0", content: .text(text)),
            SceneFixtures.layer(3, name: "text:0#1", content: .null)
        ])
        let file = try SceneFixtures.build([root])
        #expect(file.contentSlots.map(\.tag) == ["text:0#2", "text:0"])
        var composition = file.composition
        for slot in file.contentSlots {
            try await composition.apply(.text(slot.tag, layout: .automatic), forTag: slot.tag)
        }
        #expect(try composition.text(at: 0).text == "text:0#2")
        #expect(try composition.text(at: 1).text == "text:0")
        #expect(composition.contentSlots == file.contentSlots)
    }

    /// 多 tag 编辑、隐藏和恢复只作用于对应源槽，四个共享图片实例一起恢复且其它层不变。
    @Test func restoreIsPerSourceAndClearsAllOverrides() async throws {
        let file = try await EditableFixtures.file()
        var composition = file.composition
        let image = try await PAGImage.load(data: PAGFixtures.data(named: "media/imageReplacement.png"))
        try await composition.apply(.text("保留文字", layout: .automatic), forTag: "text:1")
        try await composition.apply(.image(image), forTag: "image:1")
        try composition.setPlaceholder(image, at: 1)
        try await composition.apply(.hidden, forTag: "image:1")
        let record = try #require(composition.dynamicSlotRecords().first { $0.slot.tag == "image:1" })
        for position in record.instances {
            let id = composition.storage.instances[position].id
            #expect(composition.layer(withID: id)?.isVisible == false)
        }
        try await composition.apply(.unchanged, forTag: "image:1")
        #expect(composition.edits.images.count == 4)
        try await composition.apply(.original, forTag: "image:1")
        #expect(composition.edits.images.isEmpty)
        #expect(composition.edits.placeholders.isEmpty)
        #expect(composition.edits.visibility.isEmpty)
        #expect(try composition.text(at: 1).text == "保留文字")
        #expect(try file.composition.text(at: 1).text != "保留文字")
        #expect(file.composition.edits.images.isEmpty)
    }

    /// 未开放编辑的源和无槽文件不产生业务槽；真实图片尺寸保留逻辑空间而非编码像素。
    @Test func permissionsAndLogicalSizeArePreserved() async throws {
        let none = try await EditableFixtures.file(allowedTexts: [], allowedImages: [])
        #expect(none.contentSlots.isEmpty)
        let sparse = try await EditableFixtures.file(allowedTexts: [1], allowedImages: [1])
        #expect(sparse.contentSlots.map(\.sourceIndex) == [1, 1])
        let image = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/replace.pag"))
        #expect(image.contentSlots.contains { $0.size == (try? PAGSize(width: 3027, height: 4036)) })
        let red = try await PAGLoader().load(data: PAGFixtures.data(named: "red.pag"))
        #expect(red.contentSlots.isEmpty)
    }

    /// 跑马灯后切回多行自动布局不受旧布局限制；恢复同时清文字、布局和隐藏覆盖。
    @Test func changingLayoutDoesNotValidateAgainstOldPolicy() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        var composition = file.composition
        let tag = try #require(file.contentSlots.first?.tag)
        try await composition.apply(.text("滚动文字", layout: .marquee(PAGMarqueeOptions())), forTag: tag)
        try await composition.apply(.text("第一行\n第二行", layout: .automatic), forTag: tag)
        #expect(try composition.text(at: 0).text.contains("\n"))
        try await composition.apply(.hidden, forTag: tag)
        try await composition.apply(.original, forTag: tag)
        #expect(composition.edits.texts.isEmpty && composition.edits.textOverflows.isEmpty)
        #expect(composition.edits.visibility.isEmpty)
        #expect(try composition.text(at: 0) == file.composition.text(at: 0))
    }
}
