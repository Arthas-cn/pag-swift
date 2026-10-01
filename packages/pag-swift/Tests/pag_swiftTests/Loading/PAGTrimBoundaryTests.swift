import Foundation
import Testing
@testable import pag_swift

/// Trim读取的损坏与资源边界，以及正式节点和完整文档的分发合同。
struct PAGTrimBoundaryTests {
    /// 所有44份真实载荷的每个短前缀与额外尾随都失败，不能发布部分轨道。
    @Test func everyRealPrefixAndTrailingByteFails() throws {
        var count = 0
        for url in try PAGFixtures.allPAGURLs() {
            let data = try Data(contentsOf: url)
            var inspection = ShapeAnimationInspection()
            try inspection.inspect(data)
            for payload in inspection.trimPayloads {
                let bytes = data.subdata(in: payload.range)
                for end in 0..<bytes.count {
                    #expect(throws: PAGError.self) { try TrimFixtures.read(bytes.prefix(end)) }
                }
                #expect(throws: PAGError.invalidFile(reason: "unconsumedTagPayload", offset: bytes.count)) {
                    try TrimFixtures.read(bytes + Data([0]))
                }
                count += 1
            }
        }
        #expect(count == 44)
    }

    /// 未知模式精确报unsupported；三属性全缺省和全存在两种flags布局都必须正确定位末尾Value。
    @Test(arguments: [UInt8(2), UInt8(255)]) func unknownModesFailExplicitly(_ mode: UInt8) throws {
        for data in [Data([8, mode]), TrimFixtures.constants(start: 0.2, end: 0.8, offset: 90, mode: mode)] {
            #expect(throws: PAGError.unsupportedFeature("trimPathsMode")) { try TrimFixtures.read(data) }
        }
    }

    /// 真实start/end常量及offset动画初值替换成NaN或正负Inf，按字段位置立即拒绝。
    @Test(arguments: [UInt32(0x7fc00000), UInt32(0x7f800000), UInt32(0xff800000)])
    func nonfiniteValuesFailAtTheirSourceOffset(_ bits: UInt32) throws {
        for (name, range, offset): (String, Range<Int>, Int) in [
            ("list/4.pag", 6525..<6534, 1), ("list/4.pag", 6525..<6534, 5),
            ("PAG_LOGO.pag", 9184..<9657, 460)
        ] {
            var damaged = try TrimFixtures.data(name, range: range)
            // 原始Float位置由独立字节探针核实；这是损坏真实payload，不是合成合法PAG。
            damaged.replaceSubrange(offset..<(offset + 4), with:
                (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
            #expect(throws: PAGError.invalidFile(reason: "nonfiniteScalar", offset: offset)) {
                try TrimFixtures.read(damaged)
            }
        }
    }

    /// 外壳不足时不读flags；静态和三轨动画的精确预算均可通过，少一字节必须失败。
    @Test func budgetIsReservedBeforeReadingAndPublishing() throws {
        let constant = try TrimFixtures.data("list/4.pag", range: 6525..<6534)
        var decoder = TrimFixtures.decoder(limit: 255)
        var reader = PAGByteReader(data: constant)
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
            try decoder.readTrimPaths(reader: &reader)
        }
        #expect(reader.position == 0 && decoder.budget.used == 0)
        for data in [constant, try TrimFixtures.data("PAG_LOGO.pag", range: 9184..<9657)] {
            let result = try TrimFixtures.read(data)
            #expect(result.cost >= 256)
            #expect(try TrimFixtures.read(data, limit: result.cost).cost == result.cost)
            #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
                try TrimFixtures.read(data, limit: result.cost - 1)
            }
        }
    }

    /// 预取消在读取任何flags前传播，既有静态与复杂动画都不能返回源模型或消耗预算。
    @Test func cancellationPreventsAnySourcePublication() async throws {
        for data in [try TrimFixtures.data("list/4.pag", range: 6525..<6534),
                     try TrimFixtures.data("PAG_LOGO.pag", range: 9184..<9657)] {
            await #expect(throws: CancellationError.self) {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.cancelAll()
                    group.addTask {
                        var decoder = TrimFixtures.decoder()
                        var reader = PAGByteReader(data: data)
                        defer { #expect(reader.position == 0 && decoder.budget.used == 0) }
                        _ = try decoder.readTrimPaths(reader: &reader)
                    }
                    for try await _ in group {}
                }
            }
        }
    }

    /// 正式分发保留真实静态/动画字段，节点外壳另计256字节，不可省略或绕过读取器预算。
    @Test func formalShapePreservesPayloadAndChargesBothShells() throws {
        for data in [try TrimFixtures.data("list/4.pag", range: 6525..<6534),
                     try TrimFixtures.data("wstask_circle.pag", range: 2506..<2524)] {
            let original = try TrimFixtures.read(data)
            let cost = original.cost + 256
            var decoder = TrimFixtures.decoder(limit: cost)
            var reader = PAGByteReader(data: data)
            guard case .trimPaths(let source) = try decoder.readShape(code: 25, reader: &reader, depth: 1) else {
                Issue.record("正式分发必须保留Trim节点")
                continue
            }
            for (actual, expected) in zip([source.start, source.end, source.offset],
                                          [original.source.start, original.source.end, original.source.offset]) {
                #expect(actual.initialValue == expected.initialValue)
                #expect(actual.keyframes.map(\.startValue) == expected.keyframes.map(\.startValue))
                #expect(actual.keyframes.map(\.endValue) == expected.keyframes.map(\.endValue))
                #expect(actual.keyframes.map(\.startFrame) == expected.keyframes.map(\.startFrame))
                #expect(actual.keyframes.map(\.endFrame) == expected.keyframes.map(\.endFrame))
            }
            #expect(source.mode == original.source.mode)
            #expect(decoder.budget.used == cost && reader.remainingByteCount == 0)
            var insufficient = TrimFixtures.decoder(limit: cost - 1)
            var shortReader = PAGByteReader(data: data)
            #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
                try insufficient.readShape(code: 25, reader: &shortReader, depth: 1)
            }
        }
        var decoder = TrimFixtures.decoder(limit: 511)
        var reader = PAGByteReader(data: Data([0]))
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
            try decoder.readShape(code: 25, reader: &reader, depth: 1)
        }
        #expect(reader.position == 0 && decoder.budget.used == 256)
    }

    /// 只开放25，不能用连续区间误开Merge/Repeater/RoundCorners；缓存版本同步递增。
    @Test func adjacentUnsupportedTagsRemainClosedAndRevisionAdvances() async throws {
        for tag: UInt16 in [24, 26, 27] {
            var decoder = TrimFixtures.decoder()
            var reader = PAGByteReader(data: Data([0]))
            #expect(throws: PAGError.unsupportedFeature("shapeTag:\(tag)")) {
                try decoder.readShape(code: tag, reader: &reader, depth: 1)
            }
            #expect(reader.position == 0)
        }
        let snapshot = try await LoadSnapshot.prepare(data: PAGFixtures.data(named: "red.pag"), limits: .standard)
        #expect(ParseKey(snapshot: snapshot, limits: .standard).decoderRevision == 15)
    }
}
