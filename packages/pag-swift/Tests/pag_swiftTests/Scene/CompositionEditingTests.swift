import Testing
@testable import pag_swift

/// 编辑快照的 COW、槽位与实例边界；只验证 P2 合同，不假装已经绘制。
struct CompositionEditingTests {
    /// 编码 DFS 给文本源和共享图片编号；重复预合成产生实例但不能增加槽位。
    @Test func catalogDeduplicatesSourcesInEncodingOrder() async throws {
        let file = try await EditableFixtures.file()
        #expect(file.editableTextIndices == [0, 1] && file.editableImageIndices == [0, 1])
        #expect(file.storage.catalog.imageIDs == [14, 12])
        #expect(file.storage.instances.count == 10)
        #expect(try EditableFixtures.layer(path: [21, 10], in: file.composition).editableIndex == 0)
        #expect(try EditableFixtures.layer(path: [22, 10], in: file.composition).editableIndex == 0)
        #expect(try EditableFixtures.layer(path: [23], in: file.composition).editableIndex == 1)
        #expect(try EditableFixtures.layer(path: [20], in: file.composition).editableIndex == 0)
        #expect(try EditableFixtures.layer(path: [21, 12], in: file.composition).editableIndex == 1)
    }

    /// 编辑合成副本和旧图层值不互相污染，恢复覆盖后原始文件仍保持原样。
    @Test func copiesAndLayerValuesAreSnapshots() async throws {
        let file = try await EditableFixtures.file()
        var first = file.composition
        var second = first
        let oldLayer = try EditableFixtures.layer(path: [21, 11], in: first)
        let otherInstance = try EditableFixtures.layer(path: [22, 11], in: first)
        let originalText = try first.text(at: 0)
        var changed = originalText
        changed.text = "新文字"
        try first.replaceText(changed, at: 0)
        try first.setVisibility(false, for: oldLayer.id)
        #expect(oldLayer.isVisible)
        #expect(first.layer(withID: oldLayer.id)?.isVisible == false)
        #expect(first.layer(withID: otherInstance.id)?.isVisible == true)
        #expect(try first.text(at: 0) == changed && first.text(at: 1) == originalText)
        #expect(try second.text(at: 0) == originalText)
        #expect(second.layer(withID: oldLayer.id)?.isVisible == true)
        try second.replaceText(changed, at: 1)
        #expect(try first.text(at: 1) == originalText)
        #expect(try file.composition.text(at: 0) == originalText)
        try first.replaceText(nil, at: 0)
        #expect(try first.text(at: 0) == originalText)
    }

    /// 名称只命中同名图片，索引命中所有共享实例；后写覆盖，nil 恢复源图而非旧覆盖。
    @Test func namedAndIndexedImageEditsHaveLastWriteSemantics() async throws {
        let file = try await EditableFixtures.file()
        var composition = file.composition
        let original = composition
        let first = try await PAGImage.load(data: PAGFixtures.data(named: "media/imageReplacement.png"))
        let second = try await PAGImage.load(data: PAGFixtures.data(named: "media/imageReplacement.webp"))
        let shared = composition.layers(named: "shared").filter { $0.kind == .image }
        let other = composition.layers(named: "other")
        #expect(shared.count == 3 && other.count == 2)
        try composition.replaceImage(first, at: 1)
        for layer in shared + other where layer.editableIndex == 1 {
            #expect(composition.image(for: layer.id)?.storage === first.storage)
        }
        try composition.replaceImage(second, named: "shared")
        for layer in shared { #expect(composition.image(for: layer.id)?.storage === second.storage) }
        for layer in other { #expect(composition.image(for: layer.id)?.storage === first.storage) }
        #expect(composition.edits.texts.isEmpty)
        try composition.replaceImage(nil, named: "shared")
        for layer in shared {
            #expect(composition.image(for: layer.id)?.storage === original.image(for: layer.id)?.storage)
        }
        for layer in other { #expect(composition.image(for: layer.id)?.storage === first.storage) }
        try composition.replaceImage(nil, at: 1)
        for layer in shared + other {
            #expect(composition.image(for: layer.id)?.storage === original.image(for: layer.id)?.storage)
        }
    }

    /// 显式允许集合可以稀疏；不能把 count=1 解释成只能编辑索引零。
    @Test func sparseEditableIndicesAreEnforced() async throws {
        let file = try await EditableFixtures.file(allowedTexts: [1], allowedImages: [1])
        #expect(file.editableTextCount == 1 && file.editableTextIndices == [1])
        #expect(file.editableImageCount == 1 && file.editableImageIndices == [1])
        var composition = file.composition
        #expect(throws: PAGError.invalidEditableIndex(0)) { try composition.text(at: 0) }
        #expect(throws: PAGError.invalidEditableIndex(0)) { try composition.replaceText(nil, at: 0) }
        #expect(throws: PAGError.invalidEditableIndex(0)) { try composition.replaceImage(nil, at: 0) }
        try composition.replaceText(nil, at: 1)
        try composition.replaceImage(nil, at: 1)
        #expect(try EditableFixtures.layer(path: [20], in: composition).editableIndex == 0)
        // 名称替换按图像实例匹配，不受文件的索引替换允许集合限制。
        try composition.replaceImage(nil, named: "shared")
    }

    /// 显式空集合与缺失标签不同，不能重新开放全部编辑槽。
    @Test func explicitEmptyIndicesRemainEmpty() async throws {
        let file = try await EditableFixtures.file(allowedTexts: [], allowedImages: [])
        #expect(file.editableTextCount == 0 && file.editableImageCount == 0)
        #expect(file.storage.catalog.texts.count == 2 && file.storage.catalog.imageIDs.count == 2)
        var composition = file.composition
        #expect(throws: PAGError.invalidEditableIndex(0)) { try composition.replaceText(nil, at: 0) }
        #expect(throws: PAGError.invalidEditableIndex(0)) { try composition.replaceImage(nil, at: 0) }
    }

    /// 损坏的允许列表包含越界、负值或重复值时，整个文件不能发布。
    @Test(arguments: [[-1], [2], [1, 1]])
    func invalidSourceIndicesFail(_ indices: [Int]) async throws {
        await #expect(throws: SceneValidator.invalid("invalidEditableIndices")) {
            try await EditableFixtures.file(allowedTexts: indices)
        }
        await #expect(throws: SceneValidator.invalid("invalidEditableIndices")) {
            try await EditableFixtures.file(allowedImages: indices)
        }
    }

    /// 非法样式、外来图层和无匹配名称都原子失败，已有效的编辑仍保留。
    @Test func invalidEditsLeaveSnapshotUnchanged() async throws {
        let file = try await EditableFixtures.file()
        var composition = file.composition
        var text = try composition.text(at: 0)
        text.text = "保留这次编辑"
        try composition.replaceText(text, at: 0)
        var invalid = text
        invalid.fontSize = .nan
        #expect(throws: PAGError.invalidArgument("fontSize")) { try composition.replaceText(invalid, at: 0) }
        #expect(try composition.text(at: 0) == text)
        #expect(throws: PAGError.noMatchingImageLayer("Shared")) { try composition.replaceImage(nil, named: "Shared") }
        let foreign = try await PAGLoader().load(data: PAGFixtures.data(named: "red.pag"))
        let id = try #require(foreign.composition.layers.first?.id)
        #expect(throws: PAGError.invalidLayer) { try composition.setVisibility(false, for: id) }
        #expect(composition.edits.visibility.isEmpty && composition.edits.images.isEmpty)
    }

    /// reset 一次清理所有覆盖；其他快照仍持有原有编辑及共享输入资源。
    @Test func resetRestoresAllOriginalValues() async throws {
        let file = try await EditableFixtures.file()
        var composition = file.composition
        let layer = try EditableFixtures.layer(path: [20], in: composition)
        var text = try composition.text(at: 0)
        text.text = "编辑"
        let image = try await PAGImage.load(data: PAGFixtures.data(named: "media/imageReplacement.png"))
        try composition.replaceText(text, at: 0)
        try composition.replaceImage(image, at: 0)
        try composition.setVisibility(false, for: layer.id)
        let saved = composition
        composition.resetEdits()
        #expect(try composition.text(at: 0) == file.composition.text(at: 0))
        #expect(composition.image(for: layer.id)?.storage === file.composition.image(for: layer.id)?.storage)
        #expect(composition.layer(withID: layer.id)?.isVisible == true)
        #expect(try saved.text(at: 0) == text)
        #expect(saved.image(for: layer.id)?.storage === image.storage)
        #expect(saved.layer(withID: layer.id)?.isVisible == false)
    }

    /// PAGText 的全部可变数值在构造和替换时验证，填充/描边同时为空是合法透明文字。
    @Test func textStyleValidationIsComplete() throws {
        for size in [0.0, -1, .infinity, .nan] {
            #expect(throws: PAGError.invalidArgument("fontSize")) { try PAGText(text: "", fontSize: size) }
        }
        #expect(throws: PAGError.invalidArgument("strokeWidth")) { try PAGText(text: "", fontSize: 1, strokeWidth: -1) }
        #expect(throws: PAGError.invalidArgument("leading")) { try PAGText(text: "", fontSize: 1, leading: .infinity) }
        #expect(throws: PAGError.invalidArgument("tracking")) { try PAGText(text: "", fontSize: 1, tracking: .nan) }
        let transparent = try PAGText(text: "", fontSize: 1)
        #expect(transparent.fillColor == nil && transparent.strokeColor == nil)
    }
}
