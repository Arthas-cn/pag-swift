import Foundation
import Testing
@testable import pag_swift

/// 蒙版字段的全部真实载荷与独立字段顺序核对，正式图层入口尚未开放。
struct PAGMaskReaderTests {
    /// 355项真实载荷核对蒙版分发顺序；共用属性内核，原始字节独立金值由另组用例验证。
    @Test func allRealMasksPreserveFields() async throws {
        let payloads = try await MaskFixtures.payloads()
        #expect(payloads.count == 355 && Set(payloads.map(\.name)).count == 20)
        var modes: [UInt8: Int] = [:]
        var animated = 0
        var segments = 0
        for payload in payloads {
            #expect(payload.code == 14)
            let actual = try MaskFixtures.read(payload.data).mask
            var reader = PAGByteReader(data: payload.data)
            var independent = TrimFixtures.decoder()
            // 此处独立复述MaskTag配置，不调用readMask；共享路径属性内核由已有路径专项验证。
            let flags = try PropertyFlags.read([.fixed, .flag, .flag, .property, .property, .property], from: &reader)
            let id = try reader.readEncodedUInt32()
            let mode = try flags[2].exists ? reader.readUInt8() : 1
            let path = try independent.readPathProperty(flags[3], reader: &reader)
            let opacity = try independent.readOpacityProperty(flags[4], reader: &reader)
            let expansion = try independent.readScalarProperty(flags[5], defaultValue: 0, reader: &reader)
            try StaticAttributes.requireEnd(of: reader)
            #expect(actual.id == id && actual.mode.rawValue == mode && actual.isInverted == flags[1].exists)
            #expect(actual.isInverted == false && actual.feather == nil)
            #expect(actual.opacity.initialValue == opacity.initialValue && opacity.initialValue == 255)
            #expect(actual.expansion.initialValue == expansion.initialValue && expansion.initialValue == 0)
            #expect(actual.opacity.isAnimated == false && actual.expansion.isAnimated == false)
            compare(actual.path, path)
            modes[mode, default: 0] += 1
            if path.isAnimated {
                animated += 1
                print("MASK_ANIMATED \(payload.name) range=\(payload.range) segments=\(path.keyframes.count)")
            }
            segments += path.keyframes.count
        }
        print("MASK_TOTAL payloads=\(payloads.count) files=\(Set(payloads.map(\.name)).count) animated=\(animated) segments=\(segments) modes=\(modes)")
        #expect(modes == [0: 11, 1: 20, 2: 1, 6: 323])
        #expect(animated == 10 && segments == 105)
    }

    /// 真实静态Add、ID0的Subtract及负起点动画保留，不把来源帧号误转微秒。
    @Test func selectedRealValues() throws {
        let audio = try MaskFixtures.read(PAGFixtures.data(named: "AudioMarker.pag").subdata(in: 1_971_337..<1_971_395)).mask
        #expect(audio.id == 2 && audio.mode == .add && audio.path.initialValue.verbs.count == 6)
        #expect(audio.path.initialValue.verbs.filter { $0 == .cubic }.count == 4)
        #expect(audio.path.initialValue.verbs.last == .close)
        let subtract = try MaskFixtures.read(PAGFixtures.data(named: "list/17.pag").subdata(in: 5_449..<5_491)).mask
        #expect(subtract.id == 0 && subtract.mode == .subtract)
        let animated = try MaskFixtures.read(PAGFixtures.data(named: "shanzi_video.pag").subdata(in: 7_882_483..<7_883_374)).mask
        #expect(animated.path.keyframes.count == 24)
        #expect(animated.path.keyframes.first?.startFrame == -9 && animated.path.keyframes.last?.endFrame == 15)
    }

    /// 比较每个路径端点、关键帧边界和缓动种类/采样，不用仅相同段数代替字段一致。
    private func compare(_ actual: SourceProperty<SourcePath>, _ expected: SourceProperty<SourcePath>) {
        #expect(actual.initialValue.verbs == expected.initialValue.verbs && actual.initialValue.points == expected.initialValue.points)
        #expect(actual.keyframes.count == expected.keyframes.count)
        for (a, b) in zip(actual.keyframes, expected.keyframes) {
            #expect(a.startFrame == b.startFrame && a.endFrame == b.endFrame)
            #expect(a.startValue.verbs == b.startValue.verbs && a.startValue.points == b.startValue.points)
            #expect(a.endValue.verbs == b.endValue.verbs && a.endValue.points == b.endValue.points)
            switch (a.easing, b.easing) {
            case (.none, .none), (.linear, .linear), (.hold, .hold): break
            case (.bezier(let first, let second), .bezier(let other, let otherSecond)):
                #expect(second == nil && otherSecond == nil && first.sampleCount == other.sampleCount)
                for fraction: Float in [0, 0.25, 0.5, 0.75, 1] {
                    #expect(first.timing(at: fraction) == other.timing(at: fraction))
                }
            default: Issue.record("蒙版路径缓动类型不一致")
            }
        }
    }
}
