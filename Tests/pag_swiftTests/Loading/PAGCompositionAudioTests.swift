import Foundation
import Testing
@testable import pag_swift

/// 三种合成的共同音频分发与完整真实文件保留；字段变体不冒充完整新PAG。
struct PAGCompositionAudioTests {
    /// TZ2完整文件通过公开入口，音频仍附着原源合成，没有变成图层或画面时钟。
    @Test(arguments: [("TZ2.pag", UInt32(324), 3_413)])
    func completeFilesRetainAudio(_ name: String, _ id: UInt32, _ count: Int) async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
        let source = try #require(file.storage.compositions.first { $0.id == id })
        #expect(source.audio?.bytes?.count == count && source.audio?.startFrame == 0)
        #expect(file.storage.compositions.filter { $0.audio != nil }.count == 1)
        #expect(source.audioMarkers.isEmpty)
        #expect(file.storage.estimatedBytes > count)
    }

    /// 源码允许三种合成共同读取53/55；在真实合成载荷添加独立字段，验证分发而非伪造完整文件。
    @Test(arguments: [("red.pag", UInt16(2)), ("RootLayerBitmap.pag", UInt16(45)),
                      ("RootLayerVideo.pag", UInt16(50))])
    func allCompositionKindsPreserveMetadata(_ name: String, _ code: UInt16) async throws {
        let data = try PAGFixtures.data(named: name)
        let inspection = try await PAGContainerInspector.inspect(data)
        let tag = try #require(inspection.tags.first { $0.code == code })
        let original = data.subdata(in: tag.payloadRange)
        #expect(original.suffix(2) == Data([0, 0]))
        // 只替换当前合成的End，原属性/序列仍完整保留；不是重新编码文件头或外层容器。
        let payload = Data(original.dropLast(2)) + block(53, [1, 0, 7, 0]) + block(55, [1, 42, 9])
            + block(53, [1, 0, 3, 0]) + block(55, [0, 12]) + Data([0, 0])
        var reader = PAGByteReader(data: payload)
        var decoder = TrimFixtures.decoder()
        let audio: SourceAudio?
        let markers: [SourceMarker]
        if code == 50 {
            let value = try decoder.readVideoComposition(reader: &reader)
            audio = value.audio
            markers = value.audioMarkers
            #expect(value.video.sequences.isEmpty == false)
        } else {
            let value = try decoder.readComposition(reader: &reader, isBitmap: code == 45)
            audio = value.audio
            markers = value.audioMarkers
            #expect((value.bitmap != nil) == (code == 45))
        }
        #expect(reader.remainingByteCount == 0 && audio?.bytes == nil && audio?.startFrame == 12)
        #expect(markers.map(\.startFrame) == [7, 3] && markers.map(\.comment) == ["", ""])
    }

    /// 没有音频的真实文件仍保持缺省空值，解析缓存版本须与当前画面支持范围一致。
    @Test func absentMetadataAndRevision() async throws {
        let data = try PAGFixtures.data(named: "red.pag")
        let file = try await PAGLoader().load(data: data)
        #expect(file.storage.compositions.allSatisfy { $0.audio == nil && $0.audioMarkers.isEmpty })
        let snapshot = try await LoadSnapshot.prepare(data: data, limits: .standard)
        #expect(ParseKey(snapshot: snapshot, limits: .standard).decoderRevision == 35)
    }

    /// TagHeader.h的短载荷编码；只用于已取证53/55字段，所有输入均小于63字节。
    private func block(_ code: UInt16, _ bytes: [UInt8]) -> Data {
        precondition(bytes.count < 63)
        let header = code << 6 | UInt16(bytes.count)
        return Data([UInt8(truncatingIfNeeded: header), UInt8(header >> 8)] + bytes)
    }
}
