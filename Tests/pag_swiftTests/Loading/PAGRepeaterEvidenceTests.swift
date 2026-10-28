import Foundation
import Testing
@testable import pag_swift

/// Repeater标签只按上游字段配置读取真实子流，调查结果不等同完整文件支持。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PAG_REPEATER_AUDIT"] == "1",
                "设置PAG_REPEATER_AUDIT=1调查真实Repeater字段"))
struct PAGRepeaterEvidenceTests {
    /// 沿文件、Vector、Layer和ShapeGroup边界记录tag26的字段值、长度与动画段数。
    @Test func realRepeaterPayloads() throws {
        let root = try PAGFixtures.rootURL().path + "/"
        var total = 0
        for url in try PAGFixtures.allPAGURLs() {
            let data = try Data(contentsOf: url)
            var inspection = ShapeAnimationInspection()
            try inspection.inspect(data)
            guard !inspection.repeaterPayloads.isEmpty else { continue }
            let name = url.path.replacingOccurrences(of: root, with: "")
            #expect(inspection.repeaterPayloads.count == inspection.repeaterReaders.count)
            for (payload, raw) in zip(inspection.repeaterPayloads, inspection.repeaterReaders) {
                let encoded = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
                print("PAG_REPEATER \(name) \(String(decoding: encoded, as: UTF8.self))")
                var reader = raw
                var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 64 * 1024 * 1024))
                let source = try decoder.readRepeaterProperties(reader: &reader)
                #expect(source.order == .below && source.copies.initialValue == 5)
                #expect(source.anchor.initialValue == ScenePoint(x: 0, y: 24))
                #expect(source.position.initialValue == .zero && source.scale.initialValue == .one)
                #expect(source.rotation.keyframes.count == 1 && source.isAnimated)
                #expect(source.rotation.keyframes.first?.endValue == 72)
                total += 1
            }
        }
        #expect(total > 0)
        print("PAG_REPEATER total=\(total)")
    }

    /// 真实文件全部600源帧均应能规划五份形状paint，旋转动画中段不能仅靠端点通过。
    @Test(.timeLimit(.minutes(2))) func completeRealFileFrames() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "repeater.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        #expect(root.durationFrames == 600)
        for frame in 0..<root.durationFrames {
            let prepared = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: frame, rate: root.frameRate),
                targetSize: file.composition.size, scale: 1, mode: .none)
            let paints = prepared.plan.commands.filter { if case .shape = $0 { true } else { false } }.count
            #expect(paints == 5)
        }
    }
}
