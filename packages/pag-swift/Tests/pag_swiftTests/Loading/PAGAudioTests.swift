import Foundation
import Testing
@testable import pag_swift

/// 合成音频的真实字节与源码定义字段边界；内部通过不等于完整文件可播放。
struct PAGAudioTests {
    /// 两份真实载荷保留完整容器字节、摘要和起点，不解析或改写媒体内容。
    @Test(arguments: [
        ("AudioMarker.pag", 1_805_900..<1_971_189, 165_285,
         "d6a8127e2c112740668c9693321fad7f2804e3d738cbe3f586185bd96340ea2b"),
        ("TZ2.pag", 432_423..<435_839, 3_413,
         "0688b1c26a1cd09249e931af2ee9a51303bdb5cb676742536e0241a901aed90d")
    ])
    func realBytesAndStart(_ name: String, _ range: Range<Int>, _ size: Int, _ digest: String) throws {
        let data = try PAGFixtures.data(named: name).subdata(in: range)
        let audio = try read(data).audio
        let bytes = try #require(audio.bytes)
        #expect(bytes.count == size && audio.startFrame == 0)
        #expect(try DocumentIdentity(data: bytes).digest.map { String(format: "%02x", $0) }.joined() == digest)
    }

    /// 零长度仍保留有符号帧位模式；缺失tag与显式空bytes可由外层可选值区分。
    @Test(arguments: [Int64.min, -1, 0, 127, Int64.max])
    func emptyBytesPreserveSignedStart(_ frame: Int64) throws {
        let result = try read(Data([0]) + frameBytes(frame))
        #expect(result.audio.bytes == nil && result.audio.startFrame == frame)
        #expect(result.cost == 128)
    }

    /// 截断、越界长度、varint溢出、起点缺失及尾随必须失败，不能跳过残缺音频。
    @Test func rejectsDamagedAudio() throws {
        // AudioBytes.cpp：长度2、两个容器字节、起点128；只构造字段片段，不是完整PAG。
        let valid = Data([2, 11, 22, 128, 1])
        for end in 0..<valid.count {
            #expect(throws: PAGError.self) { try read(Data(valid.prefix(end))) }
        }
        for data in [valid + Data([0]), Data([0]), Data([255, 255, 255, 255, 16]),
                     Data([0] + Array(repeating: UInt8(255), count: 10))] {
            #expect(throws: PAGError.self) { try read(data) }
        }
        // 真实大载荷分别损坏长度头、字节末端和最后起点，避免二次方地复制所有长前缀。
        let real = try PAGFixtures.data(named: "AudioMarker.pag").subdata(in: 1_805_900..<1_971_189)
        for end in [0, 1, 2, 3, real.count / 2, real.count - 2, real.count - 1] {
            #expect(throws: PAGError.self) { try read(Data(real.prefix(end))) }
        }
    }

    /// 外壳和bytes都先收费，精确预算通过、少一字节失败；预取消不读取或消耗预算。
    @Test func budgetAndCancellation() async throws {
        let bytes = Data([2, 11, 22, 0])
        #expect(try read(bytes, limit: 130).cost == 130)
        for limit in [0, 127, 129] {
            #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) { try read(bytes, limit: limit) }
        }
        await #expect(throws: CancellationError.self) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.cancelAll()
                group.addTask {
                    var decoder = TrimFixtures.decoder()
                    var reader = PAGByteReader(data: bytes)
                    defer { #expect(reader.position == 0 && decoder.budget.used == 0) }
                    _ = try decoder.readAudio(reader: &reader)
                }
                for try await _ in group {}
            }
        }
    }

    /// 重复55最后覆盖且累计收费，最后空bytes也生效；坏载荷不覆盖已完成的暂存值。
    @Test func repeatedAudioOverwritesOnlyAfterValidation() throws {
        var decoder = TrimFixtures.decoder()
        var audio: SourceAudio?
        var markers: [SourceMarker] = []
        #expect(audio == nil)
        for bytes in [Data([1, 42, 9]), Data([0, 12])] {
            var reader = PAGByteReader(data: bytes)
            #expect(try decoder.readCompositionMetadata(code: 55, reader: &reader, audio: &audio, markers: &markers))
        }
        #expect(audio?.bytes == nil && audio?.startFrame == 12 && decoder.budget.used == 257)
        var damaged = PAGByteReader(data: Data([1, 7, 3, 0]))
        #expect(throws: PAGError.self) {
            try decoder.readCompositionMetadata(code: 55, reader: &damaged, audio: &audio, markers: &markers)
        }
        #expect(audio?.startFrame == 12)
        var unknown = PAGByteReader(data: Data([1]))
        #expect(try decoder.readCompositionMetadata(code: 54, reader: &unknown, audio: &audio, markers: &markers) == false)
        #expect(unknown.position == 0)
    }

    /// 完整读取字段并返回预算，仅供内部子合同验证，不能绕过正式文件标签门禁。
    private func read(_ data: Data, limit: Int = 1_000_000) throws -> (audio: SourceAudio, cost: Int) {
        var decoder = TrimFixtures.decoder(limit: limit)
        var reader = PAGByteReader(data: data)
        let audio = try decoder.readAudio(reader: &reader)
        return (audio, decoder.budget.used)
    }

    /// 根据ReadTime的UInt64位模式编码单个帧字段，不是有符号绝对值varint。
    private func frameBytes(_ frame: Int64) -> Data {
        var value = UInt64(bitPattern: frame)
        var bytes = Data()
        repeat {
            let low = UInt8(value & 127)
            value >>= 7
            bytes.append(low | (value == 0 ? 0 : 128))
        } while value != 0
        return bytes
    }
}
