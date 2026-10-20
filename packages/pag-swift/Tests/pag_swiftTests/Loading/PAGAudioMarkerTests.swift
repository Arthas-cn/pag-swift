import Foundation
import Testing
@testable import pag_swift

/// 合成marker与图层marker共享布局但校验不同，确保完整消费和追加保持源顺序。
struct PAGAudioMarkerTests {
    /// AudioMarker的两条合成备注及起点按真实字节保留，不擅自建立画面事件。
    @Test func realCompositionMarkers() throws {
        let data = try PAGFixtures.data(named: "AudioMarker.pag").subdata(in: 1_971_191..<1_971_246)
        let values = try read(data)
        #expect(values.map(\.startFrame) == [36, 342])
        #expect(values.map(\.durationFrames) == [0, 0])
        #expect(values.map(\.comment) == ["newstar’s AudioMarker1", "newstar’s AudioMarker2"])
        for end in 0..<data.count {
            #expect(throws: PAGError.self) { try read(Data(data.prefix(end))) }
        }
        #expect(throws: PAGError.self) { try read(data + Data([0])) }
    }

    /// 三项flags连续排列，非字节对齐后才读记录；合成空备注允许，层仍拒绝。
    @Test func emptyCommentsAndOptionalDuration() throws {
        // 数量3、flags第二项有时长；第二项xyz使层的最小长度预检也通过，从而确实测到空备注校验。
        let data = Data([3, 2, 9, 0, 1, 7, 120, 121, 122, 0, 3, 0])
        let values = try read(data)
        #expect(values.map(\.startFrame) == [9, 1, 3])
        #expect(values.map(\.durationFrames) == [0, 7, 0])
        #expect(values.map(\.comment) == ["", "xyz", ""])
        #expect(throws: SceneValidator.invalid("emptyMarkerComment")) { try read(data, layer: true) }
        #expect(try read(Data([0])).isEmpty)
    }

    /// 没有55也能按编码顺序追加53，重复起点不排序、不去重；尾随失败不追加半份结果。
    @Test func repeatedListsAppendWithoutAudioDependency() throws {
        var decoder = TrimFixtures.decoder()
        var audio: SourceAudio?
        var markers: [SourceMarker] = []
        for _ in 0..<2 {
            var reader = PAGByteReader(data: Data([1, 0, 9, 0]))
            #expect(try decoder.readCompositionMetadata(code: 53, reader: &reader, audio: &audio, markers: &markers))
        }
        #expect(audio == nil && markers.map(\.startFrame) == [9, 9])
        var damaged = PAGByteReader(data: Data([1, 0, 3, 0, 0]))
        #expect(throws: PAGError.self) {
            try decoder.readCompositionMetadata(code: 53, reader: &damaged, audio: &audio, markers: &markers)
        }
        #expect(markers.count == 2)
    }

    /// 畸形UTF-8、截断时长、超大计数与预算都失败；空列表也不能绕过预取消。
    @Test func damageBudgetAndCancellation() async throws {
        for data in [Data([1, 0, 3, 255, 0]), Data([1, 1, 3, 128]), Data([255, 255, 255, 255, 15])] {
            #expect(throws: PAGError.self) { try read(data) }
        }
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
            try read(Data([1, 0, 9, 0]), limit: 127)
        }
        #expect(try read(Data([1, 0, 9, 0]), limit: 128).count == 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try read(Data([0])) }
        }
        await task.value
    }

    /// 备注预算差一字节时不能先构造并消费该串；精确成本才能返回完整marker。
    @Test func commentBudgetPrecedesStringConsumption() throws {
        let data = Data([1, 0, 9, 97, 98, 99, 0])
        var decoder = TrimFixtures.decoder(limit: 130)
        var reader = PAGByteReader(data: data)
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
            try decoder.readMarkers(reader: &reader, requiresComment: false)
        }
        #expect(reader.position == 3 && decoder.budget.used == 128)
        #expect(try read(data, limit: 131).first?.comment == "abc")
    }

    /// 标记起点及显式时长都按UInt64位模式保留，不能套用合成正时长或微秒可表示范围。
    @Test func markerFramesPreserveExtremeBitPatterns() throws {
        // ReadTime的min/max/-1固定varint布局；这里只拼接MarkerTag字段片段。
        let minimum = Array(repeating: UInt8(128), count: 9) + [1]
        let maximum = Array(repeating: UInt8(255), count: 8) + [127]
        let negative = Array(repeating: UInt8(255), count: 9) + [1]
        let values = try read(Data([2, 3] + minimum + maximum + [0] + negative + minimum + [0]))
        #expect(values.map(\.startFrame) == [Int64.min, -1])
        #expect(values.map(\.durationFrames) == [Int64.max, Int64.min])
    }

    /// 独立读取合成或层的字段片段，尾随统一失败；不构造合法PAG。
    private func read(_ data: Data, layer: Bool = false, limit: Int = 1_000_000) throws -> [SourceMarker] {
        var decoder = TrimFixtures.decoder(limit: limit)
        var reader = PAGByteReader(data: data)
        let values = try decoder.readMarkers(reader: &reader, requiresComment: layer)
        try StaticAttributes.requireEnd(of: reader)
        return values
    }
}
