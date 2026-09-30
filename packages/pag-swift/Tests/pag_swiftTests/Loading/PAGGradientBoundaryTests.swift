import Foundation
import Testing
@testable import pag_swift

/// 渐变外壳的枚举、非有限、预算、取消与尚未开放的正式入口。
struct PAGGradientBoundaryTests {
    /// 已知但未实现的type及未知值不降级，blend/composite/fillRule按字段给出明确错误。
    @Test func unsupportedEnumsFailExplicitly() throws {
        for (tag, range): (UInt16, Range<Int>) in [(22, 361..<390), (23, 326..<359)] {
            let data = try PAGFixtures.data(named: "TextAnimatorMode.pag").subdata(in: range)
            for kind: UInt8 in [2, 3, 4, 255] {
                var damaged = data
                damaged[2] = kind
                #expect(throws: PAGError.unsupportedFeature("gradientType")) { try GradientFixtures.read(tag, data: damaged) }
            }
            for (bit, value, reason): (UInt8, UInt8, String) in [
                (1, 1, "gradientBlendMode"), (2, 255, "gradientCompositeOrder")
            ] {
                var damaged = data
                // 两个Value存在位在flags前两位，新增值按源码配置插在type之前。
                damaged[0] |= bit
                damaged.insert(value, at: 2)
                #expect(throws: PAGError.unsupportedFeature(reason)) { try GradientFixtures.read(tag, data: damaged) }
            }
            var above = data
            above[0] |= 2
            above.insert(1, at: 2)
            var decoder = GradientFixtures.decoder()
            var reader = PAGByteReader(data: above)
            let order = try tag == 22 ? decoder.readGradientFill(reader: &reader).compositeOrder
                : decoder.readGradientStroke(reader: &reader).compositeOrder
            #expect(order == .abovePrevious)
        }
        var fill = try PAGFixtures.data(named: "TextAnimatorMode.pag").subdata(in: 361..<390)
        fill[0] |= 4
        fill.insert(1, at: 2)
        #expect(throws: PAGError.unsupportedFeature("gradientFillRule")) { try GradientFixtures.read(22, data: fill) }
        let stroke = try PAGFixtures.data(named: "list/10.pag").subdata(in: 3748..<3790)
        for (offset, name) in [(40, "strokeLineCap"), (41, "strokeLineJoin")] {
            var damaged = stroke
            damaged[offset] = 255
            #expect(throws: PAGError.unsupportedFeature(name)) { try GradientFixtures.read(23, data: damaged) }
        }
    }

    /// 真实startPoint与width替换为NaN/正负Inf时，错误保留字段位置，不能留给绘制阶段才发现。
    @Test(arguments: [UInt32(0x7fc00000), UInt32(0x7f800000), UInt32(0xff800000)])
    func nonfiniteFieldsFailAtSource(_ bits: UInt32) throws {
        for (tag, name, range, offset): (UInt16, String, Range<Int>, Int) in [
            (22, "list/1.pag", 159..<210, 2), (23, "TextAnimatorMode.pag", 326..<359, 29)
        ] {
            var data = try PAGFixtures.data(named: name).subdata(in: range)
            data.replaceSubrange(offset..<(offset + 4), with: (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
            #expect(throws: PAGError.invalidFile(reason: "nonfiniteScalar", offset: offset)) {
                try GradientFixtures.read(tag, data: data)
            }
        }
    }

    /// 仅重组源码定义的属性子流，验证GradientStroke的Custom位置接在miter之后，共用真实Dashes读取。
    @Test func customDashesFollowGradientStyle() throws {
        var data = try PAGFixtures.data(named: "list/10.pag").subdata(in: 3748..<3790)
        // 当前真实flags中的miter缺省，Custom为第13位；载荷取自test.pag的原始ReadDashes字段。
        data[1] |= 0x20
        data.append(try PAGFixtures.data(named: "test.pag").subdata(in: 216..<221))
        var decoder = GradientFixtures.decoder()
        var reader = PAGByteReader(data: data)
        let source = try decoder.readGradientStroke(reader: &reader)
        let dashes = try #require(source.dashes)
        #expect(source.width.initialValue == 40 && source.cap == .round && source.join == .round)
        #expect(dashes.offset.initialValue == 0 && dashes.intervals.map(\.initialValue) == [0, 10])
        #expect(source.isAnimated == false && reader.remainingByteCount == 0)
    }

    /// 外壳不足时未读flags；总预算精确边界及预取消都不返回部分材料，正式入口仍不消费payload。
    @Test func budgetsCancellationAndFormalGate() async throws {
        for (tag, range, shell): (UInt16, Range<Int>, Int) in [(22, 361..<390, 512), (23, 326..<359, 768)] {
            let data = try PAGFixtures.data(named: "TextAnimatorMode.pag").subdata(in: range)
            var limited = GradientFixtures.decoder(limit: shell - 1)
            var reader = PAGByteReader(data: data)
            #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
                if tag == 22 { _ = try limited.readGradientFill(reader: &reader) }
                else { _ = try limited.readGradientStroke(reader: &reader) }
            }
            #expect(limited.budget.used == 0 && reader.position == 0)
            let cost = try GradientFixtures.read(tag, data: data)
            #expect(try GradientFixtures.read(tag, data: data, limit: cost) == cost)
            #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
                try GradientFixtures.read(tag, data: data, limit: cost - 1)
            }
            await #expect(throws: CancellationError.self) {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.cancelAll()
                    group.addTask { _ = try GradientFixtures.read(tag, data: data) }
                    for try await _ in group {}
                }
            }
            var formal = GradientFixtures.decoder()
            var formalReader = PAGByteReader(data: data)
            #expect(throws: PAGError.unsupportedFeature("shapeTag:\(tag)")) {
                try formal.readShape(code: tag, reader: &formalReader, depth: 0)
            }
            #expect(formal.budget.used == 256 && formalReader.position == 0)
        }
    }

    /// 缺省GradientColor双空表必须明确失败，不能补白色或伪造不透明度。
    @Test func absentColorPropertyFails() throws {
        var decoder = GradientFixtures.decoder()
        var reader = PAGByteReader(data: Data())
        #expect(throws: PAGError.invalidFile(reason: "emptyGradientStops", offset: 0)) {
            try decoder.readGradientProperty(PropertyFlags(exists: false, isAnimated: false, hasSpatial: false), reader: &reader)
        }
        #expect(reader.position == 0 && decoder.budget.used == 0)
    }
}
