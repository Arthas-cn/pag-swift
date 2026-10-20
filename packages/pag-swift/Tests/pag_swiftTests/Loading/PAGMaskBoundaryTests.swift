import Foundation
import Testing
@testable import pag_swift

/// 蒙版内部读取的版本/损坏/预算边界；源码字段片段不能冒充完整文件验收。
struct PAGMaskBoundaryTests {
    /// ID0合法、八mode均保留；84缺省羽化是零轨道，14才是nil。
    @Test func defaultsVersionsAndModes() throws {
        for code: UInt16 in [14, 84] {
            let missing = try MaskFixtures.read(Data([0, 0]), code: code).mask
            #expect(missing.id == 0 && missing.isInverted == false && missing.mode == .add)
            #expect(missing.path.initialValue.verbs.isEmpty && missing.opacity.initialValue == 255)
            #expect(missing.expansion.initialValue == 0 && (missing.feather != nil) == (code == 84))
            if code == 84 { #expect(missing.feather?.initialValue == .zero) }
            for raw in UInt8(0)...7 {
                let value = try MaskFixtures.read(Data([3, 0, raw]), code: code).mask
                #expect(value.isInverted && value.mode.rawValue == raw)
            }
            #expect(throws: PAGError.unsupportedFeature("maskMode")) {
                try MaskFixtures.read(Data([2, 0, 255]), code: code)
            }
        }
        #expect(throws: PAGError.unsupportedFeature("maskTag:85")) { try MaskFixtures.read(Data(), code: 85) }
    }

    /// 常量expansion/feather允许负有限值；opacity保存字节而不是百分数。
    @Test func explicitConstantsAndNonfiniteValues() throws {
        #expect(try MaskFixtures.read(Data([16, 0]) + MaskFixtures.float(-12)).mask.expansion.initialValue == -12)
        #expect(try MaskFixtures.read(Data([8, 0, 128])).mask.opacity.initialValue == 128)
        let feather = try MaskFixtures.read(Data([8, 0]) + MaskFixtures.float(-3) + MaskFixtures.float(20), code: 84).mask
        #expect(feather.feather?.initialValue == ScenePoint(x: -3, y: 20))
        for value: Float in [.nan, .infinity, -.infinity] {
            #expect(throws: PAGError.self) { try MaskFixtures.read(Data([16, 0]) + MaskFixtures.float(value)) }
            #expect(throws: PAGError.self) {
                try MaskFixtures.read(Data([8, 0]) + MaskFixtures.float(0) + MaskFixtures.float(value), code: 84)
            }
        }
    }

    /// 非真实覆盖的属性用源码字段片段验证动画与连续位流；空间切线存在位不能丢失。
    @Test func animatedOpacityExpansionAndFeather() throws {
        // 一段线性关键帧0→10；即使没有Bezier，ReadTimeEase仍要求5位的位宽头。
        let header = Data([1, 0, 0, 10])
        let opacity = try MaskFixtures.read(Data([24, 0]) + header + MaskFixtures.bits([(7, 5), (0, 8), (255, 8), (0, 5)])).mask
        #expect(opacity.opacity.keyframes.first?.startValue == 0 && opacity.opacity.keyframes.first?.endValue == 255)
        let expansion = try MaskFixtures.read(Data([48, 0]) + header + MaskFixtures.float(-5) + MaskFixtures.float(8) + Data([0])).mask
        #expect(expansion.expansion.keyframes.first?.startValue == -5 && expansion.expansion.keyframes.first?.endValue == 8)
        // 空间点后依次是时间ease位宽、切线存在位和空间位宽；三个子流之间不能擅自对齐。
        let points = MaskFixtures.bits([(9, 5), (0, 10), (0, 10), (200, 10), (400, 10), (0, 5), (0, 2), (0, 5)])
        let feather = try MaskFixtures.read(Data([56, 0]) + header + points, code: 84).mask
        let key = try #require(feather.feather?.keyframes.first)
        #expect(key.startFrame == 0 && key.endFrame == 10 && key.startValue == .zero)
        #expect(key.endValue == ScenePoint(x: 10, y: 20) && key.spatialCurve != nil)
    }

    /// 所有真实载荷的每个短前缀和尾随均失败，不能保留半个mask或吞掉相邻标签。
    @Test func realTruncationAndTrailingBytes() async throws {
        for payload in try await MaskFixtures.payloads() {
            for end in 0..<payload.data.count {
                #expect(throws: PAGError.self) { try MaskFixtures.read(Data(payload.data.prefix(end)), code: payload.code) }
            }
            #expect(throws: PAGError.self) { try MaskFixtures.read(payload.data + Data([0]), code: payload.code) }
        }
    }

    /// 外壳不足不读flags，真实静态与动画的精确预算通过，少一字节拒绝；预取消不消耗源字节。
    @Test func budgetsAndCancellation() async throws {
        var decoder = TrimFixtures.decoder(limit: 511)
        var reader = PAGByteReader(data: Data([0, 0]))
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) { try decoder.readMask(code: 14, reader: &reader) }
        #expect(reader.position == 0 && decoder.budget.used == 0)
        for data in [Data([0, 0]), try PAGFixtures.data(named: "travel.pag").subdata(in: 2_172..<2_210)] {
            let result = try MaskFixtures.read(data)
            #expect(try MaskFixtures.read(data, limit: result.cost).cost == result.cost)
            #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) { try MaskFixtures.read(data, limit: result.cost - 1) }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var decoder = TrimFixtures.decoder()
            var reader = PAGByteReader(data: Data([0, 0]))
            #expect(throws: CancellationError.self) { try decoder.readMask(code: 14, reader: &reader) }
            #expect(reader.position == 0 && decoder.budget.used == 0)
        }
        await task.value
    }

    /// 内部读取不能自动接通图层14/84；最小Layer字段仍失败，版本17仅补None插值身份。
    @Test func formalLayerGatesRemainClosed() async throws {
        for code: UInt16 in [14, 84] {
            let header = code << 6 | 2
            // LayerTag先读类型和ID；仅给蒙版字段用于验证首个分发门禁，不是完整合法Layer或PAG。
            var reader = PAGByteReader(data: Data([1, 1, UInt8(truncatingIfNeeded: header), UInt8(header >> 8), 0, 0]))
            var decoder = TrimFixtures.decoder()
            #expect(throws: PAGError.unsupportedFeature("layerTag:\(code)")) { try decoder.readLayer(reader: &reader) }
        }
        await #expect(throws: PAGError.unsupportedFeature("layerTag:14")) {
            try await PAGLoader().load(data: PAGFixtures.data(named: "AudioMarker.pag"))
        }
        let snapshot = try await LoadSnapshot.prepare(data: PAGFixtures.data(named: "red.pag"), limits: .standard)
        #expect(ParseKey(snapshot: snapshot, limits: .standard).decoderRevision == 17)
    }
}
