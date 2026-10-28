import Foundation
import Testing
@testable import pag_swift

/// 对真实视频载荷定点破坏，验证读取器不会发布不安全索引或越界解码区域。
struct PAGVideoBoundaryTests {
    /// 截断、尺寸/alpha越界和SPS类型破坏都必须失败；测试不构造自称合法的视频位流。
    @Test func rejectsTruncationAndDamagedGeometry() async throws {
        let fixture = try await VideoDamageFixture.load()
        for count in [0, 1, 4, 10, 40, 100, 1024] {
            #expect(throws: PAGError.self) { try Self.decode(Data(fixture.data.prefix(count))) }
        }
        for offset in [0, fixture.alpha] {
            var damaged = fixture.data
            damaged[offset] = offset == 0 ? 0 : 3
            #expect(throws: PAGError.invalidFile(reason: "videoSequenceHeader", offset: nil)) {
                try Self.decode(damaged)
            }
        }
        var damaged = fixture.data
        damaged[fixture.sps] = 8
        #expect(throws: PAGError.mediaFailure("h264ParameterSets")) { try Self.decode(damaged) }
        // 保持真实双字节编码长度，只将可见宽720改为721，使颜色加alpha区域超出SPS宽度。
        damaged = fixture.data
        damaged[0] += 2
        #expect(throws: PAGError.invalidFile(reason: "videoSPSBounds", offset: nil)) { try Self.decode(damaged) }
    }

    /// PTS重复、首关键帧缺失、关键帧时间不等于编码索引和超过两帧的重排均明确失败。
    @Test func rejectsUnsafePresentationOrder() async throws {
        let fixture = try await VideoDamageFixture.load()
        var damaged = fixture.data
        damaged[fixture.times[1]] = 0
        #expect(throws: PAGError.invalidFile(reason: "videoPresentationTime", offset: nil)) { try Self.decode(damaged) }
        damaged = fixture.data
        damaged[fixture.keys] &= 0xfe
        #expect(throws: PAGError.unsupportedFeature("videoMissingInitialKeyframe")) { try Self.decode(damaged) }
        damaged = fixture.data
        damaged[fixture.keys] |= 2
        #expect(throws: PAGError.unsupportedFeature("videoKeyframeTimeline")) { try Self.decode(damaged) }
        damaged = fixture.data
        // 交换两个真实单字节PTS，保持唯一性与样本数量，但把早到帧峰值从2提高到3。
        damaged.swapAt(fixture.times[3], fixture.times[7])
        #expect(throws: PAGError.unsupportedFeature("videoReorderDepth")) { try Self.decode(damaged) }
    }

    /// 预算不足和已取消任务在系统格式解析之前结束，不能返回部分序列。
    @Test func enforcesBudgetAndCancellation() async throws {
        let fixture = try await VideoDamageFixture.load()
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
            try Self.decode(fixture.data, maximumBytes: 1024)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try Self.decode(fixture.data) }
        }
        await task.value
    }

    /// 独立读取一个实际tag51载荷；只供破坏测试，不发布完整PAG文档。
    private static func decode(_ data: Data, maximumBytes: Int = PAGLoadLimits.standard.maximumDecodedBytes) throws {
        var reader = PAGByteReader(data: data)
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: maximumBytes))
        _ = try decoder.readVideoSequence(reader: &reader, hasAlpha: true)
        try StaticAttributes.requireEnd(of: reader)
    }
}

/// 从真实RootLayerVideo中定位字段，偏移只用于损坏输入，不充当生产格式实现。
private struct VideoDamageFixture: Sendable {
    /// tag51的完整原始载荷。
    let data: Data
    /// alphaStartX的载荷内字节偏移。
    let alpha: Int
    /// 首个SPS NAL字节位置，前置长度已经跳过。
    let sps: Int
    /// 连续关键帧位流的首字节位置。
    let keys: Int
    /// 各样本PTS字段起点，与原编码顺序一致。
    let times: [Int]

    /// 用已经验证的容器和tag读取器提取首序列，返回可发送的损坏测试坐标。
    @concurrent static func load() async throws -> VideoDamageFixture {
        let data = try PAGFixtures.data(named: "RootLayerVideo.pag")
        let inspection = try await PAGContainerInspector.inspect(data)
        let tag = try #require(inspection.tags.first { $0.code == 50 })
        var root = PAGByteReader(data: data.subdata(in: tag.payloadRange))
        _ = try root.readEncodedUInt32()
        #expect(try root.readUInt8() != 0)
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: PAGLoadLimits.standard.maximumDecodedBytes))
        var sequence: Data?
        while var block = try decoder.nextBlock(from: &root) {
            if block.code == 51 {
                sequence = try block.reader.readData(byteCount: block.reader.remainingByteCount)
                break
            }
        }
        let payload = try #require(sequence)
        var reader = PAGByteReader(data: payload)
        _ = try reader.readEncodedInt32()
        _ = try reader.readEncodedInt32()
        _ = try reader.readFloat32()
        let alpha = reader.position
        _ = try reader.readEncodedInt32()
        _ = try reader.readEncodedInt32()
        let length = Int(try reader.readEncodedUInt32())
        let sps = reader.position
        try reader.skip(byteCount: length)
        let ppsLength = Int(try reader.readEncodedUInt32())
        try reader.skip(byteCount: ppsLength)
        let count = Int(try reader.readEncodedUInt32())
        let keys = reader.position
        try reader.skip(byteCount: (count + 7) / 8)
        var times: [Int] = []
        for _ in 0..<count {
            times.append(reader.position)
            _ = try StaticAttributes.frame(from: &reader)
            let length = Int(try reader.readEncodedUInt32())
            try reader.skip(byteCount: length)
        }
        return VideoDamageFixture(data: payload, alpha: alpha, sps: sps, keys: keys, times: times)
    }
}
