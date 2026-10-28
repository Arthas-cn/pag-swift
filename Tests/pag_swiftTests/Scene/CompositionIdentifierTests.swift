import Foundation
import Testing
@testable import pag_swift

/// 合成定义ID与引用ID的不同语义；纯值场景不冒充新PAG二进制夹具。
struct CompositionIdentifierTests {
    /// 六份真实文件根定义为0，正ID子合成按编码顺序保留并通过完整公开载入。
    @Test(arguments: ["0.pag", "list/0.pag", "list/12.pag", "list/13.pag", "list/15.pag", "list/19.pag"])
    func realZeroRootDefinitionsLoad(_ name: String) async throws {
        let expected: [UInt32] = switch name {
        case "list/12.pag", "list/19.pag": [1, 2, 0]
        case "list/13.pag": [1, 0]
        default: [0]
        }
        let data = try PAGFixtures.data(named: name)
        let inspection = try await PAGContainerInspector.inspect(data)
        let ids = try inspection.tags.filter { $0.code == 2 }.map { tag in
            var reader = PAGByteReader(data: data.subdata(in: tag.payloadRange))
            return try reader.readEncodedUInt32()
        }
        #expect(ids == expected)
        let file = try await PAGLoader().load(data: data)
        #expect(file.storage.compositions.map(\.id) == expected)
        #expect(!file.composition.layers.isEmpty && file.composition.duration.microseconds > 0)
    }

    /// ID0根可引用正ID子图；不可达的ID0定义也合法，根始终是最后数组记录。
    @Test func zeroDefinitionsDoNotChangeRootSelection() throws {
        let child = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, name: "child")])
        let root = try SceneFixtures.composition(0, layers: [SceneFixtures.layer(2, content: .precomposition(id: 1, startFrame: 0))])
        let first = try SceneFixtures.build([child, root])
        #expect(first.composition.layers.first?.children.first?.name == "child")
        let unreachable = try SceneFixtures.composition(0, layers: [SceneFixtures.layer(9, name: "unreachable")])
        let last = try SceneFixtures.build([unreachable, child])
        #expect(last.composition.layers.map(\.name) == ["child"])
    }

    /// 即使存在ID0定义，引用0仍是无引用，不能被字典lookup误接成合法子图。
    @Test func zeroReferenceCannotBindZeroDefinition() throws {
        let zero = try SceneFixtures.composition(0, layers: [])
        let root = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, content: .precomposition(id: 0, startFrame: 0))])
        #expect(throws: SceneValidator.invalid("missingCompositionReference")) { try SceneFixtures.build([zero, root]) }
        #expect(throws: SceneValidator.invalid("missingCompositionReference")) { try SceneFixtures.build([root]) }
    }

    /// 重复0和重复正ID都明确尚未支持上游首次匹配策略，不再误报字节损坏。
    @Test(arguments: [UInt32(0), UInt32(1)])
    func duplicateDefinitionsRemainExplicitlyUnsupported(_ id: UInt32) throws {
        let value = try SceneFixtures.composition(id, layers: [])
        #expect(throws: PAGError.unsupportedFeature("duplicateCompositionID")) { try SceneFixtures.build([value, value]) }
    }

    /// 从真实文件取已验证bitmap/video语义再构造ID0根，两种定义都遵守共同图校验规则。
    @Test(arguments: ["RootLayerBitmap.pag", "RootLayerVideo.pag"])
    func sequenceDefinitionsAlsoAllowZero(_ name: String) async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
        let source = try #require(file.storage.compositions.first { $0.bitmap != nil || $0.video != nil })
        let zero = SourceComposition(id: 0, size: source.size, durationFrames: source.durationFrames,
            frameRate: source.frameRate, background: source.background, layers: [], bitmap: source.bitmap, video: source.video)
        let result = try SceneFixtures.build([zero])
        #expect(result.storage.compositions.count == 1 && result.storage.compositions[0].id == 0)
        #expect(result.composition.duration.microseconds > 0)
    }

    /// 在真实tag50载荷上只替换已取证的定义ID字段，直接解码器也必须接受0并完整消费。
    @Test func videoReaderAcceptsZeroDefinitionField() async throws {
        let data = try PAGFixtures.data(named: "RootLayerVideo.pag")
        let inspection = try await PAGContainerInspector.inspect(data)
        let tag = try #require(inspection.tags.first { $0.code == 50 })
        let payload = data.subdata(in: tag.payloadRange)
        var prefix = PAGByteReader(data: payload)
        #expect(try prefix.readEncodedUInt32() == 65)
        // 这只是源码允许的单字段边界变体，不拼装完整PAG，也不声称原文件的正ID引用仍能成立。
        var reader = PAGByteReader(data: Data([0]) + payload.dropFirst(prefix.position))
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 64 * 1024 * 1024))
        let value = try decoder.readVideoComposition(reader: &reader)
        #expect(value.id == 0 && reader.remainingByteCount == 0)
        #expect(!value.video.sequences.isEmpty && value.attributes.duration > 0)
    }
}
