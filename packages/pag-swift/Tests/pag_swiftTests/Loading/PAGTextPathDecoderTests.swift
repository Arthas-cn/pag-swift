import Foundation
import Testing
@testable import pag_swift

/// tag69六字段的真实字节、同层路径引用、公开载入和失败边界。
struct PAGTextPathDecoderTests {
    /// 全部九份以tag69为首个障碍的资源须能由上游字段顺序完整消费真实子流。
    @Test func realTextPathPayloadsConsumeExactly() throws {
        let names = ["TextPathBox.pag", "TextPathBox2.pag", "TextPathBoxReversed.pag",
            "TextPathClosedPath.pag", "TextPathCommon.pag", "TextPathForceAlignment.pag",
            "TextPathForceAlignment2.pag", "TextPathNotPerpendicular.pag", "TextPathReversed.pag"]
        var count = 0
        for name in names {
            var inspection = ShapeAnimationInspection()
            try inspection.inspect(PAGFixtures.data(named: name))
            #expect(!inspection.textPathReaders.isEmpty, "file=\(name)")
            #expect(inspection.textPathReaders.count == inspection.textPathMasks.count)
            for (input, masks) in zip(inspection.textPathReaders, inspection.textPathMasks) {
                var reader = input
                var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 64 * 1024 * 1024))
                let value = try decoder.readTextPathOption(reader: &reader)
                #expect(value.maskID > 0)
                let mask = try #require(masks.first(where: { $0.id == value.maskID }))
                #expect(value.firstMargin.initialValue.isFinite && value.lastMargin.initialValue.isFinite)
                #expect(reader.remainingByteCount == 0)
                if ProcessInfo.processInfo.environment["PAG_TEXT_PATH_AUDIT"] == "1" {
                    print("PAG_TEXT_PATH \(name) id=\(value.maskID) reverse=\(value.reversed.initialValue)/\(value.reversed.keyframes.count) perpendicular=\(value.perpendicular.initialValue)/\(value.perpendicular.keyframes.count) force=\(value.forceAlignment.initialValue)/\(value.forceAlignment.keyframes.count) first=\(value.firstMargin.initialValue)/\(value.firstMargin.keyframes.count) last=\(value.lastMargin.initialValue)/\(value.lastMargin.keyframes.count) maskVerbs=\(mask.path.initialValue.verbs.count) maskFrames=\(mask.path.keyframes.count)")
                }
                count += 1
            }
        }
        #expect(count >= names.count)
    }

    /// 九份真实同层mask路径应全部可测，正反方向和大边距位置在有界几何预算内可求。
    @Test func realReferencedMasksCanBeMeasured() throws {
        let names = ["TextPathBox.pag", "TextPathBox2.pag", "TextPathBoxReversed.pag",
            "TextPathClosedPath.pag", "TextPathCommon.pag", "TextPathForceAlignment.pag",
            "TextPathForceAlignment2.pag", "TextPathNotPerpendicular.pag", "TextPathReversed.pag"]
        for name in names {
            var inspection = ShapeAnimationInspection()
            try inspection.inspect(PAGFixtures.data(named: name))
            for (raw, masks) in zip(inspection.textPathReaders, inspection.textPathMasks) {
                var reader = raw
                var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 64 * 1024 * 1024))
                let option = try decoder.readTextPathOption(reader: &reader)
                let mask = try #require(masks.first(where: { $0.id == option.maskID }))
                var budget = try GeometryBudget()
                let geometry = try TextPathGeometry(path: mask.path.initialValue,
                    reversed: option.reversed.initialValue, budget: &budget)
                #expect(geometry.length > 0, "file=\(name)")
                let first = try geometry.sample(at: option.firstMargin.initialValue, budget: &budget)
                let last = try geometry.sample(at: Double(geometry.length) + option.lastMargin.initialValue,
                    budget: &budget)
                #expect(first.position.x.isFinite && first.position.y.isFinite)
                #expect(last.position.x.isFinite && last.position.y.isFinite)
            }
        }
    }

    /// 正式Loader须保留tag69及同层mask，供帧计划逐帧定位字形。
    @Test func publicLoaderKeepsTextPathReference() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "TextPathCommon.pag"))
        let layer = try #require(file.storage.compositions.flatMap(\.layers).first(where: { $0.textPath != nil }))
        let option = try #require(layer.textPath)
        #expect(layer.masks.contains(where: { $0.id == option.maskID }))
    }

    /// 离散布尔动画段不读两位插值字段，零段数必须在分配前拒绝。
    @Test func emptyDiscreteTrackIsRejected() throws {
        var reader = PAGByteReader(data: Data([0]))
        let flag = PropertyFlags(exists: true, isAnimated: true, hasSpatial: false)
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 1024))
        #expect(throws: PAGError.invalidFile(reason: "emptyKeyframes", offset: nil)) {
            try decoder.readDiscreteBoolProperty(flag, defaultValue: false, reader: &reader)
        }
    }

    /// 一段离散动画只含段数、起止时间和逐位值；末值与段内保持值不得互换。
    @Test func discreteBooleanAnimationKeepsHoldAndEndpoint() throws {
        var reader = PAGByteReader(data: Data([1, 0, 10, 0b01]))
        let flag = PropertyFlags(exists: true, isAnimated: true, hasSpatial: false)
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 1024))
        let value = try decoder.readDiscreteBoolProperty(flag, defaultValue: false, reader: &reader)
        let segment = try #require(value.keyframes.first)
        #expect(segment.startFrame == 0 && segment.endFrame == 10)
        #expect(segment.startValue && !segment.endValue)
        #expect(value.keyframes.count == 1 && reader.remainingByteCount == 0)
    }
}
