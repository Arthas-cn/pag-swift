import CoreMedia
import Foundation
import Testing
import VideoToolbox
@testable import pag_swift

/// 文件tag32的真实元数据与失败语义，不将文件伸缩模式当作播放器重复次数。
struct PAGFileTimingTests {
    /// 全部24个真实载荷完整保留Repeat模式和原始范围，包括合法的0/0空范围。
    @Test func readsAllRealFileTiming() async throws {
        var count = 0
        for url in try PAGFixtures.allPAGURLs() {
            let data = try Data(contentsOf: url)
            let inspection = try await PAGContainerInspector.inspect(data)
            for tag in inspection.tags where tag.code == 32 {
                count += 1
                let value = try decode(data.subdata(in: tag.payloadRange))
                #expect(value.mode == .repeat)
                let expected: SourceTimeRange
                switch url.lastPathComponent {
                case "data-TimeStretch.pag": expected = SourceTimeRange(start: 30, end: 90)
                case "RangeSelectorTriangleEaseHighAndLow.pag": expected = SourceTimeRange(start: 0, end: 750)
                default: expected = SourceTimeRange(start: 0, end: 0)
                }
                #expect(value.scaledRange == expected)
            }
        }
        #expect(count == 24)
    }

    /// 十三份完整视频文件的0/0设置不能冻结原始播放；首末采样仍映射到不同实际视频输入。
    @Test(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264), "需要H.264硬件解码"),
          arguments: ["1", "3", "5", "6", "8", "9", "11", "12", "13", "14", "17", "18", "21"])
    func preservesOriginalPlaybackDuration(_ name: String) async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
        let storage = file.storage
        let root = storage.compositions[storage.rootIndex]
        #expect(storage.fileTiming.mode == .repeat)
        #expect(storage.fileTiming.scaledRange == SourceTimeRange(start: 0, end: 0))
        #expect(file.composition.duration == (try SceneValidator.time(frame: root.durationFrames, rate: root.frameRate)))
        let scene = try await PreparedScene.prepare(file.composition)
        let first = try await VideoPlanningFixtures.plan(scene, frame: 0)
        let last = try await VideoPlanningFixtures.plan(scene, frame: root.durationFrames - 1)
        #expect(!first.videos.isEmpty && !last.videos.isEmpty)
        #expect(Set(first.videos.keys) != Set(last.videos.keys))
    }

    /// 源码枚举0...3和无范围分支按独立字段片段验证；这些片段不是伪造的完整PAG文件。
    @Test(arguments: [SourceTimeStretchMode.none, .scale, .repeat, .repeatInverted])
    func preservesModesWithoutRange(_ mode: SourceTimeStretchMode) throws {
        let value = try decode(Data([mode.rawValue, 0]))
        #expect(value.mode == mode && value.scaledRange == nil)
    }

    /// 完整字节bool的任意非零值均表示有范围，不限制成0/1或错误读取一个bit。
    @Test func readsWholeByteBoolean() throws {
        var payload = try PAGFixtures.data(named: "1").subdata(in: 11..<15)
        payload[1] = 0xff
        #expect(try decode(payload).scaledRange == SourceTimeRange(start: 0, end: 0))
    }

    /// 截断、未知模式、未消费载荷和重复单值标签均失败；任何失败不得写入已读设置。
    @Test func rejectsDamagedOrDuplicateTiming() throws {
        let payload = try PAGFixtures.data(named: "data-TimeStretch.pag").subdata(in: 61..<65)
        for count in 0..<payload.count {
            #expect(throws: PAGError.self) { try decode(Data(payload.prefix(count))) }
        }
        var damaged = payload
        damaged[0] = 255
        #expect(throws: PAGError.unsupportedFeature("timeStretchMode:255")) { try decode(damaged) }
        damaged = payload
        damaged[1] = 0
        #expect(throws: PAGError.self) { try decode(damaged) }
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 1024))
        var reader = PAGByteReader(data: damaged)
        #expect(throws: PAGError.self) { try decoder.readFileTiming(reader: &reader) }
        #expect(decoder.fileTiming == nil)
        reader = PAGByteReader(data: payload)
        try decoder.readFileTiming(reader: &reader)
        reader = PAGByteReader(data: payload)
        #expect(throws: PAGError.invalidFile(reason: "duplicateTimeStretchMode", offset: nil)) {
            try decoder.readFileTiming(reader: &reader)
        }
        #expect(decoder.fileTiming?.scaledRange == SourceTimeRange(start: 30, end: 90))
    }

    /// 预算不足和预取消在发布设置前失败；无tag32的完整文档采用Repeat及默认全区间语义。
    @Test func enforcesBudgetCancellationAndDefaults() async throws {
        let payload = try PAGFixtures.data(named: "1").subdata(in: 11..<15)
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) { try decode(payload, budget: 1) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try decode(payload) }
        }
        await task.value
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "red.pag"))
        #expect(file.storage.fileTiming.mode == .repeat && file.storage.fileTiming.scaledRange == nil)
    }

    /// 只调用有界tag32读取入口，要求成功结果非空，不绕过完整文件的其他语义门禁。
    private func decode(_ data: Data, budget: Int = 1024) throws -> SourceFileTiming {
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: budget))
        var reader = PAGByteReader(data: data)
        try decoder.readFileTiming(reader: &reader)
        return try #require(decoder.fileTiming)
    }
}
