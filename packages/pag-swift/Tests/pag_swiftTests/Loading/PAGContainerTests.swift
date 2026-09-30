import Foundation
import Testing
@testable import pag_swift

/// 容器层测试只验收边界检查，不把顶层标签枚举当作可播放文档。
struct PAGContainerTests {
    /// 全部真实 PAG 及无后缀文件都应通过结构探查，且以零载荷 End 完整结束。
    @Test func inspectsEveryRealPAGFixture() async throws {
        let urls = try PAGFixtures.allPAGURLs()
        #expect(urls.count >= 116)
        #expect(urls.contains { $0.pathExtension.isEmpty })
        for url in urls {
            let data = try Data(contentsOf: url)
            let inspection = try await PAGContainerInspector.inspect(data)
            #expect(inspection.version == 1, "夹具：\(url.lastPathComponent)")
            #expect(inspection.bodyRange == 9..<data.count)
            let end = try #require(inspection.tags.last)
            #expect(end.code == 0)
            #expect(end.payloadRange == data.count..<data.count)
        }
    }

    /// red 的实际顶层偏移和长度来自独立源码调研，防止头解析整体错位。
    @Test func redContainerMatchesEvidence() async throws {
        let inspection = try await PAGContainerInspector.inspect(PAGFixtures.data(named: "red.pag"))
        #expect(inspection.tags.map(\.code) == [31, 2, 0])
        #expect(inspection.tags.map(\.offset) == [9, 66, 163])
        #expect(inspection.tags.map(\.payloadRange) == [11..<66, 72..<163, 165..<165])
    }

    /// PAG 入口不能把外部替换视频或任意损坏 magic 当成 PAG 容器。
    @Test func ordinaryMP4IsNotPAG() async throws {
        let video = try PAGFixtures.data(named: "game.mp4")
        await #expect(throws: PAGError.invalidFile(reason: "invalidMagic", offset: 0)) {
            try await PAGContainerInspector.inspect(video)
        }
    }

    /// 截取真实文件的每一种过短头部，都应报告截断而不是构造空结果。
    @Test(arguments: Array(0..<11))
    func truncatedHeadersFail(_ count: Int) async throws {
        let data = Data(try PAGFixtures.data(named: "red.pag").prefix(count))
        await #expect(throws: PAGError.truncatedData(offset: count)) {
            try await PAGContainerInspector.inspect(data)
        }
    }

    /// 声明长度超出真实内容时不采用上游 min 宽容策略，必须拒绝残缺结果。
    @Test func truncatedBodyFails() async throws {
        let data = Data(try PAGFixtures.data(named: "red.pag").dropLast())
        await #expect(throws: PAGError.truncatedData(offset: 164)) {
            try await PAGContainerInspector.inspect(data)
        }
    }

    /// 加密版本与未来版本给出不同 unsupported 原因，不进入普通标签解码。
    @Test func encryptedAndFutureVersionsFail() async throws {
        var data = try PAGFixtures.data(named: "red.pag")
        data[3] = 3
        await #expect(throws: PAGError.unsupportedFeature("encryptedContainer")) {
            try await PAGContainerInspector.inspect(data)
        }
        data[3] = 4
        await #expect(throws: PAGError.unsupportedVersion(4)) {
            try await PAGContainerInspector.inspect(data)
        }
    }

    /// 未压缩标记必须是字符 U，不能把数值零错误地视为合法压缩方式。
    @Test func unsupportedCompressionFails() async throws {
        var data = try PAGFixtures.data(named: "red.pag")
        data[8] = 0
        await #expect(throws: PAGError.unsupportedFeature("containerCompression:0")) {
            try await PAGContainerInspector.inspect(data)
        }
    }

    /// body 外与 End 后的额外字节分别拒绝，不能悄悄丢弃未解释内容。
    @Test func trailingBytesFail() async throws {
        var data = try PAGFixtures.data(named: "red.pag")
        data.append(0)
        await #expect(throws: PAGError.invalidFile(reason: "trailingContainerBytes", offset: 165)) {
            try await PAGContainerInspector.inspect(data)
        }
        // 损坏输入：同步增长 body 声明，使额外字节落入 End 后的 body 内。
        data[4] = 157
        await #expect(throws: PAGError.invalidFile(reason: "trailingTagBytes", offset: 165)) {
            try await PAGContainerInspector.inspect(data)
        }
    }

    /// 损坏标签的超大载荷长度不能读穿容器或触发偏移溢出。
    @Test func oversizedTagLengthFails() async throws {
        var data = try PAGFixtures.data(named: "red.pag")
        // red 的 vector 扩展长度位于 68..<72，证据见基础形状字节证据。
        data.replaceSubrange(68..<72, with: [0xff, 0xff, 0xff, 0xff])
        await #expect(throws: PAGError.truncatedData(offset: 72)) {
            try await PAGContainerInspector.inspect(data)
        }
    }

    /// 删除实际 End 并同步缩短声明后仍必须失败，完整载荷不能替代结束标签。
    @Test func missingEndTagFails() async throws {
        var data = Data(try PAGFixtures.data(named: "red.pag").dropLast(2))
        data[4] = 154
        await #expect(throws: PAGError.truncatedData(offset: 163)) {
            try await PAGContainerInspector.inspect(data)
        }
    }

    /// End 带载荷是明确的非法结构，即使声明长度与实际字节数相符也不能接受。
    @Test func endTagCannotCarryPayload() async throws {
        var data = try PAGFixtures.data(named: "red.pag")
        data[163] = 1
        data.append(0)
        data[4] = 157
        await #expect(throws: PAGError.invalidFile(reason: "endTagHasPayload", offset: 163)) {
            try await PAGContainerInspector.inspect(data)
        }
    }

    /// 内部探查保留未知 code 供支持矩阵使用，结果类型始终只是 inspection。
    @Test func unknownTagIsOnlyInspected() async throws {
        var data = try PAGFixtures.data(named: "red.pag")
        // 这是修改真实输入的结构探查用例，不宣称该变体是合法可播放 PAG。
        let word = UInt16(999 << 6 | 55)
        data[9] = UInt8(truncatingIfNeeded: word)
        data[10] = UInt8(word >> 8)
        let inspection = try await PAGContainerInspector.inspect(data)
        #expect(inspection.tags.first?.code == 999)
    }

    /// 文件和解码预算分别生效，标签记录也计入解码开销。
    @Test func resourceLimitsIncludeTagRecords() async throws {
        let data = try PAGFixtures.data(named: "red.pag")
        let smallFile = try PAGLoadLimits(maximumFileBytes: 164)
        await #expect(throws: PAGError.resourceLimitExceeded("maximumFileBytes")) {
            try await PAGContainerInspector.inspect(data, limits: smallFile)
        }
        let smallDecode = try PAGLoadLimits(maximumDecodedBytes: 165)
        await #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
            try await PAGContainerInspector.inspect(data, limits: smallDecode)
        }
    }

    /// 已取消的结构化子任务应传播 CancellationError，不返回 inspection 或包装成格式错误。
    @Test func cancellationPropagates() async throws {
        let data = try PAGFixtures.data(named: "red.pag")
        await #expect(throws: CancellationError.self) {
            try await withThrowingTaskGroup(of: PAGContainerInspection.self) { group in
                // 先取消再添加，子任务开始时必定已取消；不依赖抢占或真实睡眠。
                group.cancelAll()
                group.addTask { try await PAGContainerInspector.inspect(data) }
                for try await _ in group {}
            }
        }
    }
}
