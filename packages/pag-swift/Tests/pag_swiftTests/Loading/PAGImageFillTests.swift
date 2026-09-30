import Foundation
import Testing
@testable import pag_swift

/// 图片素材规则的真实字段与版本差异，不把AudioMarker中尚未支持的音频语义当作已播放。
struct PAGImageFillTests {
    /// 真实54保存三段帧值并把Hold修为Linear；相同布局按67读取时仍为Hold。
    @Test func realPayloadPreservesFrameValuesAndVersionSemantics() throws {
        for version: UInt16 in [54, 67] {
            let rule = try ImageTimeFixtures.realRule(version: version)
            #expect(rule.scaleMode == .aspectFit)
            #expect(rule.timeRemap.keyframes.map(\.startFrame) == [22, 173, 322])
            #expect(rule.timeRemap.keyframes.map(\.endFrame) == [173, 322, 422])
            #expect(rule.timeRemap.keyframes.map(\.startValue) == [0, 320, 355])
            #expect(rule.timeRemap.keyframes.map(\.endValue) == [320, 355, 485])
            for key in rule.timeRemap.keyframes {
                switch (version, key.easing) {
                case (54, .linear), (67, .hold): break
                default: Issue.record("ImageFillRule版本未按源码保留或修正插值")
                }
            }
        }
    }

    /// AudioMarker层329的真实完整Layer块经正式分发入口读取，规则、标记和图片引用一并保留。
    @Test func realImageLayerKeepsRuleAlongsideOtherTags() throws {
        let data = try PAGFixtures.data(named: "AudioMarker.pag").subdata(in: 1_971_252..<1_971_321)
        var reader = PAGByteReader(data: data)
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 1_000_000))
        let layer = try decoder.readLayer(reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        #expect(layer.id == 329 && layer.content.kind == .image)
        #expect(layer.imageFillRule?.timeRemap.keyframes.count == 3)
        #expect(!layer.markers.isEmpty)
        // 完整层不是完整文档；同文件compositionTag:55仍由下方用例确认失败。
        #expect(layer.startFrame == 0 && layer.durationFrames == 500)
        guard case .image(187) = layer.content else {
            Issue.record("真实图片引用必须为187")
            return
        }
    }

    /// 独立字段覆盖四种UInt8模式、默认与Int64位模式；常量不是Float32也不是有符号varint。
    @Test func defaultsModesAndSignedFrameConstants() throws {
        let missing = try decode([0])
        #expect(missing.scaleMode == .aspectFit && missing.timeRemap.initialValue == 0)
        for (raw, mode) in [PAGScaleMode.none, .stretch, .aspectFit, .aspectFill].enumerated() {
            let rule = try decode([3, UInt8(raw), 127])
            #expect(rule.scaleMode == mode && rule.timeRemap.initialValue == 127)
            #expect(!rule.timeRemap.isAnimated)
        }
        #expect(try decode([2] + Array(repeating: 255, count: 9) + [1]).timeRemap.initialValue == -1)
        #expect(try decode([2] + Array(repeating: 128, count: 9) + [1]).timeRemap.initialValue == Int64.min)
        #expect(throws: PAGError.unsupportedFeature("imageScaleMode:255")) { try decode([1, 255]) }
    }

    /// V1也必须消费完整Bezier编码再修正，V2保留实际时间曲线，不能提前按Linear跳过字节。
    @Test func bezierIsFullyReadBeforeV1Correction() throws {
        // flags=6，一段Bezier [0,10]，Frame值0/20；9位控制点(0,0)/(200,200)，精度0.005。
        let bytes: [UInt8] = [6, 1, 2, 0, 10, 0, 20, 8, 0, 0, 100, 200, 0]
        let v1 = try decode(bytes, version: 54)
        let v2 = try decode(bytes, version: 67)
        guard case .linear = v1.timeRemap.keyframes.first?.easing,
              case .bezier(let curve, _) = v2.timeRemap.keyframes.first?.easing else {
            Issue.record("版本处理丢失了Bezier消费或V1修正")
            return
        }
        #expect(curve.timing(at: 0.5) == 0.5)
        for count in 7..<bytes.count { #expect(throws: PAGError.self) { try decode(Array(bytes.prefix(count))) } }
    }

    /// 实际载荷截断、空计数、尾随、超预算和取消都不返回规则；原文件仍受音频门禁约束。
    @Test func damageBudgetCancellationAndFullFileGate() async throws {
        let data = try PAGFixtures.data(named: "AudioMarker.pag")
        let bytes = Array(data[1_971_301..<1_971_319])
        for count in 0..<bytes.count { #expect(throws: PAGError.self) { try decode(Array(bytes.prefix(count))) } }
        #expect(throws: PAGError.self) { try decode(bytes + [0]) }
        #expect(throws: SceneValidator.invalid("emptyKeyframes")) { try decode([6, 0]) }
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) { try decode(bytes, maximumBytes: 127) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try decode(bytes) }
        }
        await task.value
        await #expect(throws: PAGError.unsupportedFeature("compositionTag:55")) { try await PAGLoader().load(data: data) }
    }

    /// 只把独立字段交给真实读取入口，预算与错误保持生产语义。
    private func decode(_ bytes: [UInt8], version: UInt16 = 67, maximumBytes: Int = 1_000_000) throws -> SourceImageFillRule {
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: maximumBytes))
        var reader = PAGByteReader(data: Data(bytes))
        return try decoder.readImageFillRule(code: version, reader: &reader)
    }
}
