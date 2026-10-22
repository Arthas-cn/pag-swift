import Foundation
import Testing
@testable import pag_swift

/// 八份真实DropShadow样式的两种版本、静态值和完整边界读取。
struct PAGDropShadowEvidenceTests {
    /// 18条真实样式应由正式内部读取器完整消费，关键值保持上游文件所编码的区别。
    @Test(arguments: ["DropShadow.pag", "data-TimeStretch.pag", "guide_hand_drag.pag",
        "marker.pag", "test2.pag", "test3.pag", "vlog.pag", "zongyi2.pag"])
    func realShadowFieldFlags(_ name: String) throws {
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(PAGFixtures.data(named: name))
        #expect(!inspection.dropShadowReaders.isEmpty, "file=\(name)")
        let expectedCounts: [String: Int] = ["DropShadow.pag": 6, "data-TimeStretch.pag": 1,
            "guide_hand_drag.pag": 1, "marker.pag": 1, "test2.pag": 1,
            "test3.pag": 4, "vlog.pag": 2, "zongyi2.pag": 2]
        #expect(inspection.dropShadowReaders.count == expectedCounts[name], "file=\(name)")
        for item in inspection.dropShadowReaders {
            var reader = item.reader
            var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 64 * 1024 * 1024))
            let value = try decoder.readDropShadow(code: item.code, reader: &reader)
            #expect(reader.remainingByteCount == 0, "file=\(name)")
            #expect(value.opacity > 0 && value.size >= 0 && value.distance >= 0, "file=\(name)")
            #expect(value.distance > 0 || value.size > 0, "file=\(name)")
            #expect(value.spread == (item.code == 65 ? 1 : 0), "file=\(name)")
            if name == "DropShadow.pag" {
                #expect(value.distance == 50 && value.size == 0 && value.blendMode == 1)
            }
            if name == "marker.pag" || name == "data-TimeStretch.pag" || name == "test2.pag" {
                #expect(value.distance == 0 && value.size == 20)
                #expect(value.color.red == 255 && value.color.green == 255 && value.color.blue == 255)
            }
            if ProcessInfo.processInfo.environment["PAG_DROP_SHADOW_AUDIT"] == "1" {
                print("PAG_DROP_SHADOW file=\(name) tag=\(item.code) blend=\(value.blendMode) color=\(value.color) opacity=\(value.opacity) angle=\(value.angle) distance=\(value.distance) size=\(value.size) spread=\(value.spread)")
            }
        }
    }

    /// 动画标记不能被静态字段读取器当成颜色或数字，避免公开接线后产生错位画面。
    @Test func animatedShadowFailsBeforeStaticPayload() throws {
        var reader = PAGByteReader(data: Data([0b11]))
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 1024))
        #expect(throws: PAGError.unsupportedFeature("animatedDropShadow")) {
            try decoder.readDropShadow(code: 29, reader: &reader)
        }
    }

    /// 投影块有额外语义字节时应拒绝，不能吞掉未来版本的字段。
    @Test func trailingShadowBytesAreRejected() throws {
        var reader = PAGByteReader(data: Data([0, 0x7f]))
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 1024))
        #expect(throws: PAGError.invalidFile(reason: "unconsumedTagPayload", offset: 1)) {
            try decoder.readDropShadow(code: 29, reader: &reader)
        }
    }

    /// 纯位移、spread零Gaussian和真实V2扩散都保留原字段并公开载入。
    @Test func publicLoaderRetainsGaussianAndSpread() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "DropShadow.pag"))
        let styles = file.storage.compositions.flatMap(\.layers).flatMap(\.dropShadows)
        #expect(styles.count == 6)
        #expect(styles.allSatisfy { $0.distance == 50 && $0.size == 0 })
        let gaussian = try await PAGLoader().load(data: PAGFixtures.data(named: "marker.pag"))
        #expect(gaussian.storage.compositions.flatMap(\.layers).flatMap(\.dropShadows)
            .contains { $0.size == 20 && $0.spread == 0 })
        let spread = try await PAGLoader().load(data: PAGFixtures.data(named: "zongyi2.pag"))
        #expect(spread.storage.compositions.flatMap(\.layers).flatMap(\.dropShadows)
            .contains { $0.size == 4 && $0.spread == 1 })
    }

    /// 真实V2扩散首中末均为两层投影包一层TrackMatte，所有边界严格配平。
    @Test func realSpreadScopeStructure() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "zongyi2.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        for time in [Int64(0), file.composition.duration.microseconds / 2,
                     file.composition.duration.microseconds - 1] {
            let frame = try await FramePlanner.prepare(scene, at: PAGTime(microseconds: time),
                targetSize: scene.composition.size, scale: 1, mode: .none)
            var shadow = 0, matte = 0, maxShadow = 0, maxMatte = 0
            for command in frame.plan.commands {
                switch command {
                case .beginDropShadow: shadow += 1; maxShadow = max(maxShadow, shadow)
                case .endDropShadow: shadow -= 1
                case .beginTrackMatte: matte += 1; maxMatte = max(maxMatte, matte)
                case .endTrackMatte: matte -= 1
                default: break
                }
            }
            #expect(shadow == 0 && matte == 0)
            #expect(maxShadow == 2 && maxMatte == 1)
        }
    }

    /// 真实手势样式的变换矩阵固定留作非轴对齐模糊回归输入。
    @Test func realRotatedShadowMatrix() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "guide_hand_drag.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        var found = 0
        for time in [Int64(0), file.composition.duration.microseconds / 2,
                     file.composition.duration.microseconds - 1] {
            let frame = try await FramePlanner.prepare(scene, at: PAGTime(microseconds: time),
                targetSize: scene.composition.size, scale: 1, mode: .none)
            for command in frame.plan.commands {
                guard case .beginDropShadow(let value) = command else { continue }
                found += 1
                #expect(value.styles[0].size == 16)
                #expect(value.matrix.b != 0 && value.matrix.c != 0)
                let size = try DropShadowOffset.displayBlurSize(style: value.styles[0], shadow: value)
                #expect(abs(size.x - 16) < 0.0001 && abs(size.y - 16) < 0.0001)
            }
        }
        #expect(found > 0)
    }
}
