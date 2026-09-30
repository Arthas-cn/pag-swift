import Foundation
import Testing
@testable import pag_swift

/// 视频字节闭包、时间索引和完整文件载入验收；可见显示另由集成测试与demo核对。
struct PAGVideoTests {
    /// 所有52条真实序列的SPS/PPS、关键帧、PTS和透明区域都可完整读取，索引映射不丢样本。
    @Test func readsEveryRealEmbeddedSequence() async throws {
        let sequences = try await PAGVideoFixtures.allSequences()
        #expect(sequences.count == 52)
        for sequence in sequences {
            #expect(sequence.decodedSize.width >= Double(sequence.videoWidth))
            #expect(sequence.decodedSize.height >= Double(sequence.videoHeight))
            #expect(sequence.keyframes.first == 0)
            #expect(sequence.presentationOrder.count == sequence.samples.count)
            for index in sequence.samples.indices {
                #expect(sequence.sampleIndex(at: sequence.samples[index].frame) == index)
            }
        }
    }

    /// 真实左右/上下PAG透明区域和奇数补齐分别保留，不能强制搬成VAP左右分屏。
    @Test func preservesAlphaOffsetsAndOddVisibleSize() async throws {
        let horizontal = try #require(await PAGVideoFixtures.compositions(in: "RootLayerVideo.pag").first?.video.sequences.last)
        #expect(horizontal.width == 720 && horizontal.height == 1080)
        #expect(horizontal.videoWidth == 1440 && horizontal.videoHeight == 1080)
        #expect(horizontal.alphaStartX == 720 && horizontal.alphaStartY == 0)
        #expect(horizontal.samples.prefix(5).map(\.frame) == [0, 4, 2, 1, 3])
        #expect(horizontal.samples.count == 240 && horizontal.keyframes.count == 4)
        let vertical = try #require(await PAGVideoFixtures.compositions(in: "alpha.pag").first?.video.sequences.last)
        #expect(vertical.alphaStartX == 0 && vertical.alphaStartY == 720)
        #expect(vertical.videoWidth == 1280 && vertical.videoHeight == 1440)
        let odd = try #require(await PAGVideoFixtures.compositions(in: "particle_video.pag").first?.video.sequences.last)
        #expect(odd.width == 405 && odd.alphaStartX == 406 && odd.videoWidth == 812)
    }

    /// 真实末端缺失PTS选择之后首个样本；不把样本数错误地改成最大PTS加一。
    @Test(arguments: [("12", 90, Int64(89), Int64(92)), ("13", 60, 59, 62), ("14", 96, 95, 96),
                      ("8", 72, 71, 74), ("9", 72, 71, 72)])
    func keepsSparsePresentationTimes(_ value: (String, Int, Int64, Int64)) async throws {
        let sequence = try #require(await PAGVideoFixtures.compositions(in: value.0).first?.video.sequences.last)
        #expect(sequence.samples.count == value.1)
        #expect(sequence.samples[sequence.sampleIndex(at: value.2)].frame == value.3)
    }

    /// 静态区间和多分辨率沿用上游选择；输入编码顺序不因PTS排序而改变。
    @Test func mapsStaticRangesAndKeyframeSeeks() async throws {
        let freeze = try #require(await PAGVideoFixtures.compositions(in: "RootLayerVideoFreeze.pag").first)
        #expect(try freeze.video.frame(at: 239, frameRate: freeze.attributes.frameRate) == 0)
        let offset = try #require(await PAGVideoFixtures.compositions(in: "RootLayerVideoOffset.pag").first)
        #expect(try offset.video.frame(at: 9, frameRate: offset.attributes.frameRate) == 0)
        #expect(try offset.video.frame(at: 10, frameRate: offset.attributes.frameRate) == 10)
        let multi = try #require(await PAGVideoFixtures.compositions(in: "data_video.pag").first?.video)
        #expect(multi.sequences.count == 4)
        #expect(multi.sequences.last?.width == 720 && multi.sequences.last?.frameRate == 24)
        let sequence = try #require(await PAGVideoFixtures.compositions(in: "RootLayerVideo.pag").first?.video.sequences.last)
        #expect(sequence.sampleIndex(at: 1) == 3)
        #expect(sequence.keyframeIndex(before: 59) == 0)
        #expect(sequence.keyframeIndex(before: 60) == 60)
        #expect(sequence.keyframeIndex(before: 119) == 60)
    }

    /// 视频已接通共同绘制后，完整真实文件才可通过公开载入；其他未支持语义仍不能被跳过。
    @Test(arguments: ["RootLayerVideo.pag", "RootLayerVideoFreeze.pag", "RootLayerVideoOffset.pag",
                      "MultiVideoSequence.pag", "MultiVideoSequenceOffset.pag", "data_video.pag",
                      "particle_video.pag", "jisha.pag"])
    func loadsCompleteVideoDocuments(_ name: String) async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: name))
        #expect(file.storage.compositions.contains { $0.video != nil })
        #expect(file.storage.compositions.filter { $0.video != nil }.allSatisfy { $0.layers.isEmpty && $0.bitmap == nil })
        #expect(file.composition.duration.microseconds > 0)
    }

    /// 视频解码可用不能掩盖alpha.pag的track matte依赖，完整场景仍明确拒绝未支持语义。
    @Test func completeFileStillRejectsUnsupportedMatte() async throws {
        await #expect(throws: PAGError.unsupportedFeature("trackMatte")) {
            try await PAGLoader().load(data: PAGFixtures.data(named: "alpha.pag"))
        }
    }
}
