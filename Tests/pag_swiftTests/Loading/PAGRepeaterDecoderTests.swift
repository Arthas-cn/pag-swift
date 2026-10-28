import Foundation
import Testing
@testable import pag_swift

/// Repeater标签独立字段边界，验证默认值和非法order不会发布部分源属性。
struct PAGRepeaterDecoderTests {
    /// 九个属性flags全缺省时必须恢复上游RepeaterTag定义的每个默认值。
    @Test func allDefaultFlagsKeepSourceDefaults() throws {
        let value = try read(Data([0, 0]))
        #expect(value.order == .below && value.copies.initialValue == 3)
        #expect(value.offset.initialValue == 0 && value.anchor.initialValue == .zero)
        #expect(value.position.initialValue == ScenePoint(x: 100, y: 100))
        #expect(value.scale.initialValue == .one && value.rotation.initialValue == 0)
        #expect(value.startOpacity.initialValue == 255 && value.endOpacity.initialValue == 255)
    }

    /// 未定义order、缺少Value字节与尾随字节分别报告非法值、截断和未消费输入。
    @Test func orderAndBoundaryFailuresStayExplicit() throws {
        #expect(throws: PAGError.invalidFile(reason: "unknownRepeaterOrder", offset: 2)) {
            try read(Data([1, 0, 2]))
        }
        #expect(throws: PAGError.truncatedData(offset: 2)) { try read(Data([1, 0])) }
        #expect(throws: PAGError.invalidFile(reason: "unconsumedTagPayload", offset: 2)) {
            try read(Data([0, 0, 0]))
        }
    }

    /// 按源配置独立读取有界子流，预算不够时必须在返回源模型前失败。
    private func read(_ data: Data) throws -> SourceRepeater {
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 64 * 1024 * 1024))
        var reader = PAGByteReader(data: data)
        return try decoder.readRepeaterProperties(reader: &reader)
    }
}
