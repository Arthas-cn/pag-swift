import Foundation
import Testing
@testable import pag_swift

/// 真实图层标记的位旗标、时间与备注读取；不将音频标记或完整复杂场景视为已支持。
struct PAGMarkerTests {
    /// 实际marker.pag的三组标记保留省略时长为零及显式时长，不混淆时间和备注顺序。
    @Test func preservesRealMarkerLists() throws {
        let data = try PAGFixtures.data(named: "marker.pag")
        let first = try decode(data.subdata(in: 239..<257))
        #expect(first.map(\.startFrame) == [11, 28, 57])
        #expect(first.map(\.durationFrames) == [0, 10, 0])
        #expect(first.map(\.comment) == ["2-1", "2-2", "2-3"])
        let second = try decode(data.subdata(in: 1158..<1171))
        #expect(second.map(\.startFrame) == [19, 34])
        #expect(second.map(\.durationFrames) == [5, 0])
        #expect(second.map(\.comment) == ["5-1", "5-2"])
        let third = try decode(data.subdata(in: 1673..<1680))
        #expect(third.map(\.startFrame) == [27])
        #expect(third.map(\.comment) == ["7-1"])
        let alpha = try decode(PAGFixtures.data(named: "alpha.pag").subdata(in: 1402619..<1402641))
        #expect(alpha.map(\.comment) == ["{\"videoTrack\" : 1}"])
    }

    /// 真实载荷的所有截断及空备注、虚增计数均失败，不能把残缺元数据当作可忽略标签。
    @Test func rejectsDamagedMarkerLists() throws {
        let data = try PAGFixtures.data(named: "marker.pag").subdata(in: 239..<257)
        for count in 0..<data.count {
            #expect(throws: PAGError.self) { try decode(Data(data.prefix(count))) }
        }
        var damaged = data
        // 首字节计数、第二字节时长旗标、第三字节起点；只破坏真实首备注的首字符。
        damaged[3] = 0
        #expect(throws: PAGError.invalidFile(reason: "emptyMarkerComment", offset: nil)) {
            try decode(damaged)
        }
        damaged = data
        damaged[0] = 127
        #expect(throws: PAGError.self) { try decode(damaged) }
    }

    /// 分配预算与取消均在返回标记列表前生效，不泄露半份元数据。
    @Test func enforcesBudgetAndCancellation() async throws {
        let data = try PAGFixtures.data(named: "marker.pag").subdata(in: 239..<257)
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
            try decode(data, maximumBytes: 128)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try decode(data) }
        }
        await task.value
    }

    /// 只读取真实tag53的有界载荷；偏移用于固定证据回归，不参与生产解码。
    private func decode(_ data: Data, maximumBytes: Int = 4096) throws -> [SourceMarker] {
        var reader = PAGByteReader(data: data)
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: maximumBytes))
        let markers = try decoder.readMarkers(reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        return markers
    }
}
