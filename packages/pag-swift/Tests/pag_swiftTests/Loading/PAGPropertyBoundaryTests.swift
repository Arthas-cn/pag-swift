import Foundation
import Testing
@testable import pag_swift

/// 属性子块的损坏、计数、位边界及选择规则；片段不冒充完整 PAG 文件。
struct PAGPropertyBoundaryTests {
    /// 真实 Transform2D 的任意字节截断均失败，不能将缺失动画字段默认为常量。
    @Test func everyTruncatedTransformFails() throws {
        let payload = try transformPayload()
        for length in 0..<payload.count {
            var decoder = decoder()
            var reader = PAGByteReader(data: Data(payload.prefix(length)))
            #expect(throws: PAGError.self) { try decoder.readTransform(reader: &reader) }
        }
    }

    /// 空段数与倒序端点是非法格式；从真实文件只修改目标字段即可验证完整失败路径。
    @Test func invalidKeyframesRejectWholeDocument() async throws {
        var empty = try PAGFixtures.data(named: "replacement.pag")
        empty[11998] = 0
        await #expect(throws: SceneValidator.invalid("emptyKeyframes")) { try await PAGSceneDecoder.decode(empty) }
        var reversed = try PAGFixtures.data(named: "replacement.pag")
        reversed[12001] = 60
        await #expect(throws: SceneValidator.invalid("invalidKeyframeTimes")) { try await PAGSceneDecoder.decode(reversed) }
    }

    /// 极大数量与缺少时间字节的数量必须在分配轨道前失败，保守预算不能先被消耗。
    @Test func countsFailBeforeAllocation() throws {
        let animated = PropertyFlags(exists: true, isAnimated: true, hasSpatial: false)
        var decoder = decoder()
        var excessive = PAGByteReader(data: Data([0xff, 0xff, 0xff, 0xff, 0x0f]))
        #expect(throws: PAGError.resourceLimitExceeded("maximumKeyframes")) {
            try decoder.readScalarProperty(animated, defaultValue: 0, reader: &excessive)
        }
        var insufficient = PAGByteReader(data: Data([100, 0, 0]))
        #expect(throws: PAGError.truncatedData(offset: 1)) {
            try decoder.readScalarProperty(animated, defaultValue: 0, reader: &insufficient)
        }
        #expect(decoder.budget.used == 0)
    }

    /// 真实两段轨道的列表预算与缓动折线预算分别受限，不能只限制原始文件字节数。
    @Test(arguments: [511, 1024])
    func keyframesAndCurvesRespectBudget(_ limit: Int) throws {
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: limit))
        var reader = PAGByteReader(data: try transformPayload())
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
            try decoder.readTransform(reader: &reader)
        }
    }

    /// 时间控制点 x 超范围与非有限值都拒绝；y overshoot 仍由正常数值测试覆盖。
    @Test func invalidValuesAndTimingCoordinatesFail() throws {
        var invalidCurve = try transformPayload()
        // 原片段偏移 47 是位宽 9 的起点；后续九位 out.x 改为补码 -1，即 -0.005。
        invalidCurve[47] |= 0xe0
        invalidCurve[48] |= 0x3f
        var decoder = decoder()
        var curve = PAGByteReader(data: invalidCurve)
        #expect(throws: SceneValidator.invalid("invalidTimingControlPoint")) {
            try decoder.readTransform(reader: &curve)
        }
        var nonfinite = try transformPayload()
        nonfinite.replaceSubrange(23..<27, with: [0, 0, 0xc0, 0x7f])
        var value = PAGByteReader(data: nonfinite)
        #expect(throws: PAGError.invalidFile(reason: "nonfiniteScalar", offset: 23)) {
            try decoder.readTransform(reader: &value)
        }
    }

    /// UInt8 值列表不能把 9 位的 256 截断成零，必须报告输入损坏。
    @Test func opacityDoesNotWrapOutOfRangeValue() throws {
        // ReadKeyframes/ReadTimeAndValue：一段线性 [0,10]；位宽 9 的值为 [0,256]。
        var reader = PAGByteReader(data: Data([1, 1, 0, 10, 8, 0, 64, 0]))
        var decoder = decoder()
        #expect(throws: SceneValidator.invalid("invalidOpacityValue")) {
            try decoder.readOpacityProperty(PropertyFlags(exists: true, isAnimated: true, hasSpatial: false), reader: &reader)
        }
    }

    /// 动画 combined 即使每个值都为零也优先于非零 x；选择不能在逐帧求值时改变。
    @Test func animatedZeroPositionWinsOverSeparateX() throws {
        // flags：position 动画、无切线、x 常量；一段 Hold [0,10]、两个零 Point、x=10。
        var reader = PAGByteReader(data: Data([0x16, 0, 1, 3, 0, 10, 0, 0, 0, 0, 32, 65]))
        var decoder = decoder()
        let transform = try decoder.readTransform(reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        guard case .combined(let property) = transform.position else {
            Issue.record("动画 combined 必须优先")
            return
        }
        #expect(property.isAnimated)
        for frame: Int64 in [-1, 0, 5, 10, 11] {
            #expect(try transform.value(at: frame).position == .zero)
        }
    }

    /// 取消已发生时，轨道读取不发布部分结果，并保持 CancellationError 类型。
    @Test func cancelledPropertyDecodeStops() async throws {
        let data = try transformPayload()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var decoder = decoder()
            var reader = PAGByteReader(data: data)
            return try decoder.readTransform(reader: &reader)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 保留真实 replacement 的整个 Transform2D 载荷，偏移见求值证据记录。
    private func transformPayload() throws -> Data {
        let data = try PAGFixtures.data(named: "replacement.pag")
        return Data(data[11980..<12073])
    }

    /// 每次失败测试独立分配预算，避免前一次失败的保留计量影响后续断言。
    private func decoder() -> PAGSceneDecoder {
        PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 1_000_000))
    }
}
