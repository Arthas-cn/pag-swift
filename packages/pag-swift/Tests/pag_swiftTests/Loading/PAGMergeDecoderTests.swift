import Foundation
import Testing
@testable import pag_swift

/// MergePaths的真实固定字段、未知模式和预算边界；字段成功不代表Boolean模式已可绘制。
struct PAGMergeDecoderTests {
    /// 126份资源的84个真实载荷都完整消费，51个Append及33个Intersect与独立扫描一致。
    @Test func realPayloadsPreserveModeAndBoundary() throws {
        var counts = [Int](repeating: 0, count: 5)
        for url in try PAGFixtures.allPAGURLs() {
            let file = try Data(contentsOf: url)
            var inspection = ShapeAnimationInspection()
            try inspection.inspect(file)
            for payload in inspection.mergePayloads {
                let data = file.subdata(in: payload.range)
                var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 64 * 1024 * 1024))
                var reader = PAGByteReader(data: data)
                guard case .mergePaths(let mode) = try decoder.readShape(code: 24, reader: &reader, depth: 1) else {
                    Issue.record("真实tag24未保留MergePaths源节点")
                    continue
                }
                try StaticAttributes.requireEnd(of: reader)
                #expect(mode.rawValue == payload.mode && reader.remainingByteCount == 0)
                counts[Int(mode.rawValue)] += 1
                var trailing = PAGByteReader(data: data + Data([0]))
                var trial = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 64 * 1024 * 1024))
                _ = try trial.readShape(code: 24, reader: &trailing, depth: 1)
                #expect(throws: PAGError.invalidFile(reason: "unconsumedTagPayload", offset: 1)) {
                    try StaticAttributes.requireEnd(of: trailing)
                }
            }
        }
        #expect(counts == [51, 0, 0, 33, 0])
    }

    /// 单字节字段截断、未知值和外壳预算不足均失败，不发布半个SourceShape。
    @Test func truncatedUnknownAndBudgetFailureAreExplicit() throws {
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 255))
        var reader = PAGByteReader(data: Data([0]))
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
            try decoder.readShape(code: 24, reader: &reader, depth: 1)
        }
        #expect(reader.position == 0 && decoder.budget.used == 0)
        for data in [Data(), Data([5]), Data([255])] {
            var source = PAGByteReader(data: data)
            var trial = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 1024))
            #expect(throws: PAGError.self) { try trial.readShape(code: 24, reader: &source, depth: 1) }
        }
    }

    /// 真实list/3第77帧即使由动态store采样，完整静态证书仍须给Picture内几何稳定身份。
    @Test func realMergeShapePictureUsesCertifiedStaticIdentity() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "list/3.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        let frame = try await FramePlanner.prepare(scene,
            at: SceneValidator.time(frame: 77, rate: root.frameRate),
            targetSize: try PAGSize(width: 200, height: 200), scale: 1, mode: .aspectFit)
        var inside = false
        var markers = 0
        var shapes = 0
        for command in frame.plan.commands {
            switch command {
            case .beginPicture:
                inside = true
                markers += 1
            case .endPicture:
                inside = false
            case .shape(let paint) where inside:
                shapes += 1
                #expect(paint.geometryID.sampleFrame == nil)
            default: break
            }
        }
        #expect(markers > 0 && shapes > 0)
    }
}
