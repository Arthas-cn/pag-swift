import Testing
@testable import pag_swift

/// 用真实资源和直接语义 DAG 组合编辑边界；不拼接自称有效的 PAG 文件。
enum EditableFixtures {
    /// 子合成引用两次，共享文字源和图片槽；根层再提供同名不同种类及独立槽。
    static func file(allowedTexts: [Int]? = nil, allowedImages: [Int]? = nil) async throws -> PAGFile {
        let textFile = try await PAGLoader.shared.load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        let imageFile = try await PAGLoader.shared.load(data: PAGFixtures.data(named: "editing/ImageDecodeTest.pag"))
        let text = try #require(textFile.storage.catalog.texts.first)
        var resources = imageFile.storage.resources
        resources.allowedTexts = allowedTexts
        resources.allowedImages = allowedImages
        let child = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(10, name: "shared", content: .text(text)),
            SceneFixtures.layer(11, name: "shared", content: .image(12)),
            SceneFixtures.layer(12, name: "other", content: .image(12))
        ])
        let root = try SceneFixtures.composition(2, layers: [
            SceneFixtures.layer(20, name: "shared", content: .image(14)),
            SceneFixtures.layer(21, name: "A", content: .precomposition(id: 1, startFrame: 0)),
            SceneFixtures.layer(22, name: "B", content: .precomposition(id: 1, startFrame: 0)),
            SceneFixtures.layer(23, name: "shared", content: .text(text))
        ])
        return try SceneFixtures.build([child, root], resources: resources)
    }

    /// 取得某个语义路径的公开实例，路径不存在时让测试失败。
    static func layer(path: [UInt32], in composition: PAGComposition) throws -> PAGLayer {
        let index = try #require(composition.storage.instances.firstIndex { $0.id.path == path })
        return try #require(composition.layer(withID: composition.storage.instances[index].id))
    }
}
