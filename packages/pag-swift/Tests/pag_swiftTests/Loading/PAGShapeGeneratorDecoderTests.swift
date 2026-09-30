import Foundation
import Testing
@testable import pag_swift

/// 椭圆与星形内部字段读取的真实载荷和失败边界；不将读取成功记为整文件播放支持。
struct PAGShapeGeneratorDecoderTests {
    /// 真实Ellipse含尺寸与非零位置，真实Star/Polygon保留缺省点数和未被Polygon消费的内半径。
    @Test func realValuesAndDefaultsRemainExact() throws {
        var decoder = makeDecoder()
        var ellipseReader = try reader("list/10.pag", range: 2615..<2632)
        let ellipse = try decoder.readEllipse(reader: &ellipseReader)
        #expect(ellipseReader.remainingByteCount == 0 && ellipse.isAnimated == false && ellipse.reversed == false)
        #expect(ellipse.size.initialValue == ScenePoint(x: 132, y: 132))
        #expect(ellipse.position.initialValue == ScenePoint(x: 0, y: 42))
        var starReader = try reader("TextDirection.pag", range: 1107..<1121)
        let star = try decoder.readPolyStar(reader: &starReader)
        #expect(starReader.remainingByteCount == 0 && star.kind == .star && star.reversed == false)
        #expect(star.isAnimated == false && star.points.initialValue == 5 && star.position.initialValue == .zero)
        #expect(star.rotation.initialValue == 121.71331787109375)
        #expect(star.innerRadius.initialValue == 121.1104736328125)
        #expect(star.outerRadius.initialValue == 242.220947265625)
        #expect(star.innerRoundness.initialValue == 0 && star.outerRoundness.initialValue == 0)
        var polygonReader = try reader("alpha2.pag", range: 1933..<1948)
        let polygon = try decoder.readPolyStar(reader: &polygonReader)
        #expect(polygonReader.remainingByteCount == 0 && polygon.kind == .polygon && polygon.isAnimated == false)
        #expect(polygon.points.initialValue == 5 && polygon.position.initialValue == .zero)
        #expect(polygon.rotation.initialValue == 141.9759979248047)
        #expect(polygon.innerRadius.initialValue == 110.39114379882812)
        #expect(polygon.outerRadius.initialValue == 220.78228759765625)
        #expect(polygon.innerRoundness.initialValue == 0 && polygon.outerRoundness.initialValue == 0)
        #expect(decoder.budget.used == 192 + 512 * 2)
    }

    /// 每个真实目标载荷逐字节截短或追加尾随均失败，不能发布只读了一部分的源属性。
    @Test(arguments: [(UInt16(17), "PAG_LOGO.pag", 317..<326),
                      (UInt16(17), "list/10.pag", 2615..<2632),
                      (UInt16(18), "TextDirection.pag", 1107..<1121),
                      (UInt16(18), "alpha2.pag", 1933..<1948)])
    func truncationAndTrailingBytesFail(_ tag: UInt16, _ name: String, _ range: Range<Int>) throws {
        let data = try PAGFixtures.data(named: name).subdata(in: range)
        for end in 0..<data.count {
            #expect(throws: PAGError.self) { try read(tag, data: data.prefix(end)) }
        }
        #expect(throws: PAGError.invalidFile(reason: "unconsumedTagPayload", offset: data.count)) {
            try read(tag, data: data + Data([0]))
        }
    }

    /// 真实Polygon的枚举字节改成未定义值，必须报unsupported而不是采用上游else的Polygon降级。
    @Test func unknownKindFailsExplicitly() throws {
        var damaged = try PAGFixtures.data(named: "alpha2.pag").subdata(in: 1933..<1948)
        damaged[2] = 255
        #expect(throws: PAGError.unsupportedFeature("polyStarKind")) { try read(18, data: damaged) }
    }

    /// 真实尺寸和旋转Float改为NaN/Inf，错误保留字段偏移，不推迟到几何或Metal才检查。
    @Test(arguments: [UInt32(0x7fc00000), UInt32(0x7f800000), UInt32(0xff800000)])
    func nonfiniteFieldsFailAtReadBoundary(_ bits: UInt32) throws {
        for (tag, name, range, offset): (UInt16, String, Range<Int>, Int) in [
            (17, "PAG_LOGO.pag", 317..<326, 1), (18, "alpha2.pag", 1933..<1948, 3)
        ] {
            var damaged = try PAGFixtures.data(named: name).subdata(in: range)
            damaged.replaceSubrange(offset..<(offset + 4), with: (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
            #expect(throws: PAGError.invalidFile(reason: "nonfiniteScalar", offset: offset)) {
                try read(tag, data: damaged)
            }
        }
    }

    /// 新读取器外壳先扣费；预取消连静态真实载荷也不能成功返回，预算刚好足够时完整消费。
    @Test func shellBudgetsAndCancellation() async throws {
        for (tag, name, range, shell): (UInt16, String, Range<Int>, Int) in [
            (17, "PAG_LOGO.pag", 317..<326, 192), (18, "alpha2.pag", 1933..<1948, 512)
        ] {
            let data = try PAGFixtures.data(named: name).subdata(in: range)
            #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
                try read(tag, data: data, maximumBytes: shell - 1)
            }
            #expect(try read(tag, data: data, maximumBytes: shell) == data.count)
            await #expect(throws: CancellationError.self) {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.cancelAll()
                    group.addTask { _ = try read(tag, data: data) }
                    for try await _ in group {}
                }
            }
        }
    }

    /// 显示门禁通过后正式分发返回完整节点，256字节源节点与属性外壳均计费。
    @Test func formalEntriesDecodeWithBothShells() throws {
        for (tag, name, range, shell): (UInt16, String, Range<Int>, Int) in [
            (17, "PAG_LOGO.pag", 317..<326, 192), (18, "alpha2.pag", 1933..<1948, 512)
        ] {
            var decoder = makeDecoder(maximumBytes: 256 + shell)
            var input = try reader(name, range: range)
            let shape = try decoder.readShape(code: tag, reader: &input, depth: 0)
            switch shape {
            case .ellipse(let value): #expect(tag == 17 && value.size.initialValue.x == 397.8999938964844)
            case .polyStar(let value): #expect(tag == 18 && value.kind == .polygon)
            default: Issue.record("正式生成器入口返回了其他节点")
            }
            #expect(input.remainingByteCount == 0 && decoder.budget.used == 256 + shell)
            var limited = makeDecoder(maximumBytes: 255 + shell)
            var retry = try reader(name, range: range)
            #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
                try limited.readShape(code: tag, reader: &retry, depth: 0)
            }
        }
    }

    /// 建立独立解码预算，避免每个读取测试依赖共享游标或全局状态。
    private func makeDecoder(maximumBytes: Int = 64 * 1024 * 1024) -> PAGSceneDecoder {
        PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: maximumBytes))
    }

    /// 只截取已核实的真实payload，不合成任何声称合法的PAG字段。
    private func reader(_ name: String, range: Range<Int>) throws -> PAGByteReader {
        try PAGByteReader(data: PAGFixtures.data(named: name).subdata(in: range))
    }

    /// 调用内部字段读取器并返回实际消费量；其他标签属于测试调用错误。
    private func read(_ tag: UInt16, data: Data, maximumBytes: Int = 64 * 1024 * 1024) throws -> Int {
        var decoder = makeDecoder(maximumBytes: maximumBytes)
        var reader = PAGByteReader(data: data)
        switch tag {
        case 17: _ = try decoder.readEllipse(reader: &reader)
        case 18: _ = try decoder.readPolyStar(reader: &reader)
        default: throw PAGError.invalidArgument("shapeGeneratorTestTag")
        }
        return reader.position
    }
}
