import Foundation
import Testing
@testable import pag_swift

/// 来源明确的独立 LayerBlock 片段；只测试字段读取，不作为完整 PAG 成功证据。
struct PAGLayerBlockTests {
    /// LayerAttributes 三个版本均能建立静态 null 层；默认起点零、显示位一、时长 30 帧。
    @Test(arguments: [UInt16(6), 52, 62])
    func readsNullLayerAttributeVersions(_ version: UInt16) throws {
        let layer = try decodeLayer(type: 1, attributesVersion: version)
        #expect(layer.id == 1 && layer.name.isEmpty)
        #expect(layer.isActive && layer.parentID == nil)
        #expect(layer.startFrame == 0 && layer.durationFrames == 30)
        #expect(layer.content.kind == .null)
        #expect(try layer.transform.value(at: 0) == SceneFixtures.transform)
    }

    /// SolidColorTag 的 RGB 位于尺寸之前，尺寸是有符号可变整数而非 Float32。
    @Test func readsSolidPayload() throws {
        let layer = try decodeLayer(type: 2, content: tag(7, payload: [12, 34, 56, 20, 40]))
        guard case let .solid(size, color) = layer.content else {
            Issue.record("应读取单色层")
            return
        }
        #expect(size == (try PAGSize(width: 10, height: 20)))
        #expect(color == SceneColor(red: 12, green: 34, blue: 56))
    }

    /// CompositionReference 保存源 ID 和独立 compositionStartTime，不能丢掉后者。
    @Test func readsCompositionReference() throws {
        let layer = try decodeLayer(type: 6, content: tag(12, payload: [2, 7]))
        guard case let .precomposition(id, start) = layer.content else {
            Issue.record("应读取预合成引用")
            return
        }
        #expect(id == 2 && start == 7)
        #expect(layer.startFrame == 0)
    }

    /// Solid/PreCompose 不能只凭类型构造空内容，必须存在对应的内容标签。
    @Test(arguments: [UInt8(2), 6])
    func missingRequiredContentFails(_ type: UInt8) throws {
        #expect(throws: PAGError.invalidFile(reason: "missingLayerContent", offset: nil)) {
            try decodeLayer(type: type)
        }
    }

    /// 54/67只属于image且均为单值规则；重复、跨版本重复和错层标签不能被忽略。
    @Test func imageFillRuleRequiresImageAndUniqueRecord() throws {
        for version: UInt16 in [54, 67] {
            let content = tag(11, payload: [1]) + tag(version, payload: [0])
            let layer = try decodeLayer(type: 5, content: content)
            #expect(layer.imageFillRule?.scaleMode == .aspectFit)
            #expect(layer.imageFillRule?.timeRemap.initialValue == 0)
            #expect(throws: SceneValidator.invalid("duplicateImageFillRule")) {
                try decodeLayer(type: 5, content: content + tag(67, payload: [0]))
            }
            #expect(throws: SceneValidator.invalid("imageFillRuleInNonImageLayer")) {
                try decodeLayer(type: 1, content: tag(version, payload: [0]))
            }
        }
    }

    /// 依据 LayerTag、LayerAttributes 和 Transform2D 的配置生成独立记录片段。
    private func decodeLayer(type: UInt8, attributesVersion: UInt16 = 52, content: [UInt8] = []) throws -> SourceLayer {
        // V1 无 name flag，仅一字节 flags；V2/V3 默认值仍需第二个 flags 字节。
        let attributes: [UInt8] = attributesVersion == 6 ? [1, 30] : [1, 0, 30]
        let bytes = [type, 1] + tag(attributesVersion, payload: attributes) + tag(13, payload: [0]) + content + [0, 0]
        var reader = PAGByteReader(data: Data(bytes))
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 1_000_000))
        return try decoder.readLayer(reader: &reader)
    }

    /// 用已证实的短标签头包住单元测试载荷；所有调用的长度都小于 63。
    private func tag(_ code: UInt16, payload: [UInt8]) -> [UInt8] {
        let word = code << 6 | UInt16(payload.count)
        return [UInt8(truncatingIfNeeded: word), UInt8(word >> 8)] + payload
    }
}
