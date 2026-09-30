import Foundation
import Testing
@testable import pag_swift

/// 真实 bitmap 文件的字节证据、完整载入和安全失败，不生成合法 PAG 字节。
struct PAGBitmapTests {
    /// 四个真实根/预合成 bitmap 文件应完整载入；选择最后一条分辨率，关键帧数量匹配独立探查。
    @Test(arguments: ["RootLayerBitmap.pag", "RootLayerBitmapFreeze.pag", "RootLayerBitmapOffset.pag", "small.pag"])
    func loadsRealBitmapFiles(_ name: String) async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
        let composition = try #require(file.storage.compositions.first { $0.bitmap != nil })
        let bitmap = try #require(composition.bitmap)
        let sequence = try #require(bitmap.sequences.last)
        #expect(sequence.width == 720)
        #expect(sequence.frameRate == 24)
        #expect(sequence.frames.count == (name == "small.pag" ? 72 : 240))
        #expect(bitmap.sequences.count == (name == "small.pag" ? 4 : 1))
        #expect(composition.layers.isEmpty)
        if name == "RootLayerBitmap.pag" {
            #expect(sequence.frames.filter(\.isKeyframe).count == 4)
            let patch = try #require(sequence.frames.first?.patches.first)
            #expect(patch.x == 0 && patch.y == 10 && patch.data.count == 4710)
        }
        if name == "RootLayerBitmapFreeze.pag" {
            #expect(sequence.frames[1].isEmpty)
            #expect(try bitmap.frameIndex(at: 1, frameRate: composition.frameRate) == 0)
            #expect(try bitmap.frameIndex(at: 239, frameRate: composition.frameRate) == 0)
        }
    }

    /// 对真实序列的截断片段、零尺寸、越界矩形和极小预算均明确失败，不得到部分文档。
    @Test func rejectsDamagedSequenceAndBudget() async throws {
        let data = try PAGFixtures.data(named: "RootLayerBitmap.pag")
        var reader = PAGByteReader(data: data)
        // 独立探查确认序列 tag 位于82，长标签头6字节，首矩形数据始于133。
        try reader.skip(byteCount: 88)
        let payload = try reader.readData(byteCount: data.count - 92)
        for count in [0, 1, 4, 10, 40, 100, 1024] {
            var fragment = PAGByteReader(data: Data(payload.prefix(count)))
            var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: PAGLoadLimits.standard.maximumDecodedBytes))
            #expect(throws: (any Error).self) { try decoder.readBitmapSequence(reader: &fragment) }
        }
        var damaged = data
        damaged[88] = 0
        await #expect(throws: PAGError.self) { try await PAGLoader().load(data: damaged) }
        // 首矩形 x/y 的绝对偏移来自前述 tag/帧位流；encoded 3 表示 -1，不能写到画布之前。
        for offset in [129, 130] {
            damaged = data
            damaged[offset] = 3
            await #expect(throws: PAGError.invalidFile(reason: "bitmapPatchBounds", offset: nil)) {
                try await PAGLoader().load(data: damaged)
            }
        }
        damaged = data
        damaged[96] = 0xff
        damaged[97] = 0xff
        await #expect(throws: PAGError.self) { try await PAGLoader().load(data: damaged) }
        let limits = try PAGLoadLimits(maximumDecodedBytes: 1_000_000)
        await #expect(throws: PAGError.self) { try await PAGLoader(limits: limits).load(data: data) }
    }
}
