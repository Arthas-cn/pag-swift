import Foundation
import Testing
@testable import pag_swift

/// GradientColor字段的排序、限制和关键值边界；只构造有源码证据的字段原语，不伪造完整PAG。
struct PAGGradientColorsTests {
    /// 单项、奇数倒序与跨表同位置均合法；排序必须携带本项中点与通道一起移动。
    @Test(arguments: [[UInt16(0)], [50000, 25000, 0], [60000, 30000, 10, 50000, 1]])
    func sortPreservesWholeStops(_ positions: [UInt16]) throws {
        let source = try GradientFixtures.colors(field(alpha: positions, rgb: positions)).0
        let sorted = positions.sorted()
        #expect(source.alphaStops.map(\.position) == sorted.map { Float($0) * 0.00002 })
        #expect(source.colorStops.map(\.position) == source.alphaStops.map(\.position))
        #expect(source.alphaStops.map(\.opacity) == sorted.map { UInt8(truncatingIfNeeded: $0) })
        #expect(source.colorStops.map(\.color.red) == source.alphaStops.map(\.opacity))
        #expect(source.alphaStops.map(\.midpoint) == sorted.map { Float($0 % 50001) * 0.00002 })
    }

    /// 每张表分别拒绝重复原位置，不将排序顺序当成等键hardstop的来源。
    @Test(arguments: [true, false])
    func duplicateSourcePositionsFail(_ alpha: Bool) throws {
        let bytes = field(alpha: alpha ? [1, 0, 1] : [0, 1], rgb: alpha ? [0, 1] : [1, 0, 1])
        #expect(throws: PAGError.unsupportedFeature("gradientDuplicateSourceStops")) {
            try GradientFixtures.colors(bytes)
        }
    }

    /// UInt16全位置范围在Float中保留，中点0与1接受而超过1明确未支持，不能夹值。
    @Test func precisionAndMidpointBoundsRemainExplicit() throws {
        let data = field(alpha: [0, 65535], rgb: [0, 65535])
        let value = try GradientFixtures.colors(data).0
        #expect(value.alphaStops.last?.position == Float(65535) * 0.00002)
        #expect(try #require(value.alphaStops.last).position > 1)
        for midpoint: UInt16 in [0, 50000, 50001, 65535] {
            for offset in [4, 14] {
                // 两计数之后alpha起点为2、RGB起点为12；仅损坏相应项的UInt16 midpoint。
                var changed = data
                changed.replaceSubrange(offset..<(offset + 2), with: littleEndian(midpoint))
                if midpoint <= 50000 {
                    let colors = try GradientFixtures.colors(changed).0
                    #expect((offset == 4 ? colors.alphaStops[0].midpoint : colors.colorStops[0].midpoint)
                            == Float(midpoint) * 0.00002)
                } else {
                    #expect(throws: PAGError.unsupportedFeature("gradientMidpointRange")) {
                        try GradientFixtures.colors(changed)
                    }
                }
            }
        }
    }

    /// 双表任一为空均保留值起点偏移；先验证完整剩余字节，不为短输入分配stop数组。
    @Test func emptyAndShortTablesFailBeforeAllocation() throws {
        for counts: [UInt8] in [[0, 1], [1, 0], [0, 0]] {
            var reader = PAGByteReader(data: Data([255] + counts))
            _ = try reader.readUInt8()
            var decoder = GradientFixtures.decoder()
            #expect(throws: PAGError.invalidFile(reason: "emptyGradientStops", offset: 1)) {
                try decoder.readGradientColors(reader: &reader)
            }
            #expect(decoder.budget.used == 128)
        }
        let bytes = field(alpha: [0, 50000], rgb: [0, 50000])
        for end in 2..<bytes.count {
            var reader = PAGByteReader(data: bytes.prefix(end))
            var decoder = GradientFixtures.decoder()
            #expect(throws: PAGError.truncatedData(offset: 2)) { try decoder.readGradientColors(reader: &reader) }
            #expect(decoder.budget.used == 128 && reader.position == 2)
        }
    }

    /// 每表4096项可完整排序，4097与UInt32最大计数在数组分配前按资源政策拒绝。
    @Test func stopCountLimitAppliesToBothTables() throws {
        let positions = (0..<4096).reversed().map { UInt16($0) }
        let value = try GradientFixtures.colors(field(alpha: positions, rgb: positions)).0
        #expect(value.alphaStops.count == 4096 && value.colorStops.count == 4096)
        #expect(value.alphaStops.first?.position == 0 && value.colorStops.last?.position == Float(4095) * 0.00002)
        for large: UInt32 in [4097, .max] {
            for counts in [[large, 1], [1, large]] {
                var decoder = GradientFixtures.decoder()
                var reader = PAGByteReader(data: variable(counts[0]) + variable(counts[1]))
                #expect(throws: PAGError.resourceLimitExceeded("maximumGradientStops")) {
                    try decoder.readGradientColors(reader: &reader)
                }
                #expect(decoder.budget.used == 128)
            }
        }
    }

    /// 双表外壳、数组及归并工作逐步预付，失败预算不回滚，精确完整预算才能发布颜色值。
    @Test func tableAndSortingBudgetsNeverPublishPrefixes() throws {
        let bytes = field(alpha: [30, 10, 20], rgb: [30, 10, 20])
        let cost = try GradientFixtures.colors(bytes).1
        #expect(try GradientFixtures.colors(bytes, limit: cost).1 == cost)
        // 覆盖值外壳、stop存储、读取步进、第一归并缓冲、排序途中及最终重复检查。
        for limit in [127, 128, 128 + 6 * 64 - 1, 128 + 6 * 80, 128 + 6 * 80 + 3 * 128 + 32, cost - 1] {
            var decoder = GradientFixtures.decoder(limit: limit)
            var reader = PAGByteReader(data: bytes)
            #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
                try decoder.readGradientColors(reader: &reader)
            }
            #expect(decoder.budget.used <= limit)
            #expect(decoder.budget.used >= (limit < 128 ? 0 : 128))
            let used = decoder.budget.used
            #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) { try decoder.budget.reserve(limit + 1) }
            #expect(decoder.budget.used == used)
        }
    }

    /// 真实两段颜色动画的中间关键值减一项仍合法，相邻段共享完整对象，最终值不沿用起点表长。
    @Test func animatedValuesMayHaveDifferentStopCounts() throws {
        var bytes = try PAGFixtures.data(named: "list/1.pag").subdata(in: 714..<846)
        // 仅重组已调查的属性子流：中间表从56起，2 alpha/3 RGB，最后RGB七字节在82..<89。
        bytes[57] = 2
        bytes.removeSubrange(82..<89)
        var decoder = GradientFixtures.decoder()
        var reader = PAGByteReader(data: bytes)
        let property = try decoder.readGradientFill(reader: &reader).gradient.colors
        try #require(property.keyframes.count == 2)
        #expect(property.keyframes.map { $0.startValue.colorStops.count } == [3, 2])
        #expect(property.keyframes.map { $0.endValue.colorStops.count } == [2, 3])
        #expect(property.keyframes[0].endValue === property.keyframes[1].startValue)
        #expect(reader.remainingByteCount == 0)
    }

    /// 中间及最后关键值同样执行空表/重复检查，不能仅验证initialValue后就返回动画。
    @Test func everyAnimatedValueIsValidated() throws {
        let bytes = try PAGFixtures.data(named: "list/1.pag").subdata(in: 714..<846)
        for start in [56, 89] {
            var empty = bytes
            empty[start] = 0
            var decoder = GradientFixtures.decoder()
            var reader = PAGByteReader(data: empty)
            #expect(throws: PAGError.invalidFile(reason: "emptyGradientStops", offset: start)) {
                try decoder.readGradientFill(reader: &reader)
            }
            var duplicate = bytes
            duplicate.replaceSubrange((start + 7)..<(start + 9), with: [0, 0])
            #expect(throws: PAGError.unsupportedFeature("gradientDuplicateSourceStops")) {
                try GradientFixtures.read(22, data: duplicate)
            }
        }
    }

    /// 最大表预取消时在任何计费和读取之前退出；不使用睡眠推断取消发生时机。
    @Test func cancelledColorReadLeavesBudgetUntouched() async throws {
        let bytes = field(alpha: Array(0..<4096), rgb: Array(0..<4096))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.cancelAll()
            group.addTask {
                var decoder = GradientFixtures.decoder()
                var reader = PAGByteReader(data: bytes)
                #expect(throws: CancellationError.self) { try decoder.readGradientColors(reader: &reader) }
                #expect(decoder.budget.used == 0 && reader.position == 0)
            }
            for try await _ in group {}
        }
    }

    /// 按DataTypes.cpp::ReadGradientColor构造字段原语；通道/中点由位置生成，便于检查排序是否移动完整项。
    private func field(alpha: [UInt16], rgb: [UInt16]) -> Data {
        var result = variable(UInt32(alpha.count)) + variable(UInt32(rgb.count))
        for position in alpha {
            result += littleEndian(position) + littleEndian(position % 50001) + Data([UInt8(truncatingIfNeeded: position)])
        }
        for position in rgb {
            result += littleEndian(position) + littleEndian(position % 50001) + Data([UInt8(truncatingIfNeeded: position), 0, 255])
        }
        return result
    }

    /// UInt16小端字段原语，只用于色标位置与中点，不形成tag或文件头。
    private func littleEndian(_ value: UInt16) -> Data {
        Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)])
    }

    /// DecodeStream对应的EncodedUInt32原语，保证限制测试也覆盖多字节计数。
    private func variable(_ value: UInt32) -> Data {
        var remaining = value
        var result = Data()
        repeat {
            let byte = UInt8(remaining & 127)
            remaining >>= 7
            result.append(byte | (remaining == 0 ? 0 : 128))
        } while remaining != 0
        return result
    }
}
