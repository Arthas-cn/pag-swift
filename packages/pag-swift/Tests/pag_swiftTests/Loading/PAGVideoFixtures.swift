import Foundation
import Testing
@testable import pag_swift

/// 从真实PAG提取独立视频块供内部阶段验收；不把其他未知标签跳过后发布为PAGFile。
enum PAGVideoFixtures {
    /// 由真实独立视频块建立语义合成，验证独立媒体与组合绘制；不冒充完整文件载入。
    @concurrent static func source(in name: String) async throws -> SourceComposition {
        let value = try #require(await compositions(in: name).first)
        return SourceComposition(id: value.id, size: value.attributes.size, durationFrames: value.attributes.duration,
                                 frameRate: value.attributes.frameRate, background: value.attributes.background,
                                 layers: [], video: value.video)
    }

    /// 验证容器后逐个读取完整video合成；返回值只供测试，未知video内标签仍按生产读取器失败。
    @concurrent static func compositions(in name: String) async throws
        -> [(id: UInt32, attributes: CompositionAttributes, video: SourceVideoComposition)] {
        let data = try PAGFixtures.data(named: name)
        let inspection = try await PAGContainerInspector.inspect(data)
        var values: [(id: UInt32, attributes: CompositionAttributes, video: SourceVideoComposition)] = []
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: PAGLoadLimits.standard.maximumDecodedBytes))
        for tag in inspection.tags where tag.code == 50 {
            var reader = PAGByteReader(data: data)
            try reader.skip(byteCount: tag.payloadRange.lowerBound)
            var payload = try reader.readSubreader(byteCount: tag.payloadRange.count)
            values.append(try decoder.readVideoComposition(reader: &payload))
        }
        return values
    }

    /// 在后台枚举所有真实视频合成，不根据文件名决定是否有视频；返回值可跨隔离。
    @concurrent static func allSequences() async throws -> [SourceVideoSequence] {
        var result: [SourceVideoSequence] = []
        let root = try PAGFixtures.rootURL()
        for url in try PAGFixtures.allPAGURLs() {
            let name = String(url.path.dropFirst(root.path.count + 1))
            for composition in try await compositions(in: name) { result += composition.video.sequences }
        }
        return result
    }
}
