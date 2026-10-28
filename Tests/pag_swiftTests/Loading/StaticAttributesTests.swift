import Foundation
import Testing
@testable import pag_swift

/// 独立属性片段只验证上游明确的字段规则，不把拼接片段当作合法 PAG 文件。
struct StaticAttributesTests {
    /// ReadTime 的有符号语义来自 UInt64 位模式，不能按 sign-magnitude 还原。
    @Test func framePreservesSignedBitPattern() throws {
        // WriteTime(-1) 先转 UInt64.max，再按七位编码输出这十字节。
        var reader = PAGByteReader(data: Data(Array(repeating: UInt8(0xff), count: 9) + [1]))
        #expect(try StaticAttributes.frame(from: &reader) == -1)
    }

    /// FixedValue 不占位，BitFlag 为零保持 false；所有 flags 读完后才消费值。
    @Test func flagBlockSeparatesFlagsFromValues() throws {
        var reader = PAGByteReader(data: Data([0b0000_0100, 99]))
        let flags = try StaticAttributes.flags([.fixed, .flag, .property, .property], from: &reader)
        #expect(flags == [true, false, false, true])
        #expect(try reader.readUInt8() == 99)
    }

    /// combined position 缺省为零时分离 x/y 生效，非零 combined 则优先于分离位置。
    @Test func positionPrecedenceMatchesLayerTag() throws {
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 1_000_000))
        // 每个存在 Property 再读一个 false 动画位；Float32 值均为 little-endian。
        var separated = PAGByteReader(data: Data([0b0001_0100, 0] + floats([10, 20])))
        #expect(try decoder.readTransform(reader: &separated).value(at: 0).position == ScenePoint(x: 10, y: 20))
        var combined = PAGByteReader(data: Data([0b0010_1010, 0] + floats([1, 2, 10, 20])))
        #expect(try decoder.readTransform(reader: &combined).value(at: 0).position == ScenePoint(x: 1, y: 2))
    }

    /// 形状递归的内部限制必须在下降前生效；深度 64 允许，65 返回资源错误。
    @Test func shapeDepthIsBounded() throws {
        for depth in [64, 65] {
            var reader = PAGByteReader(data: nestedGroupPayload(depth: depth))
            var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 1_000_000))
            if depth == 64 {
                _ = try decoder.readShape(code: 15, reader: &reader, depth: 1)
                #expect(reader.remainingByteCount == 0)
            } else {
                #expect(throws: PAGError.resourceLimitExceeded("maximumShapeDepth")) {
                    try decoder.readShape(code: 15, reader: &reader, depth: 1)
                }
            }
        }
    }

    /// 将测试标量转换为 DataTypes.cpp::ReadFloat 的固定四字节片段。
    private func floats(_ values: [Float]) -> [UInt8] {
        values.flatMap { value in
            (0..<4).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) }
        }
    }

    /// 只构造 ShapeGroup 载荷片段；布局来自 ShapeGroupTag 与 TagHeader，不含 PAG 文件头。
    private func nestedGroupPayload(depth: Int) -> Data {
        // 无属性的组占两个 flags 字节；Custom 是第九位，置位时跟着子标签与 End。
        var payload = Data([0, 0])
        for _ in 1..<depth {
            let word = UInt16(15 << 6 | 63)
            var outer = Data([0, 1, UInt8(truncatingIfNeeded: word), UInt8(word >> 8)])
            let count = UInt32(payload.count)
            outer.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: count >> ($0 * 8)) })
            outer.append(payload)
            outer.append(contentsOf: [0, 0])
            payload = outer
        }
        return payload
    }
}
