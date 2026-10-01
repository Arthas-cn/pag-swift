import Foundation
import Testing
@testable import pag_swift

/// Trim内部字段读取与独立原始探针对照；不把有界payload成功宣称为整文件播放支持。
struct PAGTrimDecoderTests {
    /// 44份真实载荷的三条轨道逐值/时间/缓动类型一致，实际文件只有mode0，包含40份动画。
    @Test func allRealPayloadsMatchRawFields() throws {
        var count = 0, files = 0, animated = 0
        var animatedTracks = [0, 0, 0], segments = [0, 0, 0]
        for url in try PAGFixtures.allPAGURLs() {
            var inspection = ShapeAnimationInspection()
            try inspection.inspect(Data(contentsOf: url))
            if inspection.trimPayloads.isEmpty == false { files += 1 }
            for payload in inspection.trimPayloads {
                let raw = try PAGTrimAuditTests.inspect(payload)
                var reader = payload.reader
                var decoder = TrimFixtures.decoder()
                let source = try decoder.readTrimPaths(reader: &reader)
                #expect(reader.remainingByteCount == 0 && source.mode == .simultaneously && raw.kind == 0)
                let properties = [source.start, source.end, source.offset]
                for (index, fields) in [raw.start, raw.end, raw.offset].enumerated() {
                    try compare(properties[index], with: fields)
                    segments[index] += fields.kinds.count
                    if properties[index].isAnimated { animatedTracks[index] += 1 }
                }
                if source.isAnimated { animated += 1 }
                count += 1
            }
        }
        #expect(count == 44 && files == 10 && animated == 40)
        #expect(animatedTracks == [35, 26, 1] && segments == [89, 69, 2])
    }

    /// 独立确认真实常量和唯一offset动画的端值；默认字段不受附近动画轨道影响。
    @Test func realConstantsAndOffsetTrackRemainExact() throws {
        let fixed = try TrimFixtures.read(TrimFixtures.data("list/4.pag", range: 6525..<6534)).source
        #expect(fixed.start.initialValue == 0.28999999165534973 && fixed.end.initialValue == 1)
        #expect(fixed.offset.initialValue == 0 && fixed.isAnimated == false)
        let source = try TrimFixtures.read(TrimFixtures.data("PAG_LOGO.pag", range: 9184..<9657)).source
        let frames = source.offset.keyframes
        try #require(frames.count == 2)
        #expect(frames.map(\.startFrame) == [34, 60] && frames.map(\.endFrame) == [60, 82])
        #expect(frames[0].startValue == 69.900001525878906)
        #expect(frames[0].endValue == 117.80000305175781 && frames[1].startValue == frames[0].endValue)
        #expect(frames[1].endValue == 172.60000610351562)
    }

    /// 缺省end严格保留100，源码定义的模式1属性子流可读；宽范围有限值不提前夹值或取余。
    @Test func defaultsAndSourceDefinedModePreserveRawValues() throws {
        // 仅属性子流：三个属性缺省各占一位，mode存在占第四位；不构造完整PAG。
        for (data, mode): (Data, SourceTrimMode) in [(Data([0]), .simultaneously), (Data([8, 1]), .individually)] {
            let result = try TrimFixtures.read(data)
            #expect(result.source.start.initialValue == 0 && result.source.end.initialValue == 100)
            #expect(result.source.offset.initialValue == 0 && result.source.mode == mode)
            #expect(result.source.isAnimated == false && result.cost == 256)
        }
        let source = try TrimFixtures.read(TrimFixtures.constants(start: -20, end: 100,
            offset: Float.greatestFiniteMagnitude, mode: 1)).source
        #expect(source.start.initialValue == -20 && source.end.initialValue == 100)
        #expect(source.offset.initialValue == Double(Float.greatestFiniteMagnitude) && source.mode == .individually)
    }

    /// 三个位置分别保存同值Hold轨道时仍识别动画，不根据端点相等错误降为静态。
    @Test(arguments: 0..<3) func everyTrackRetainsAnimationIdentity(_ field: Int) throws {
        var properties = [SourceProperty<Double>(constant: 0), SourceProperty(constant: 1), SourceProperty(constant: 0)]
        let value = properties[field].initialValue
        properties[field] = try SourceProperty(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 10,
            startValue: value, endValue: value, easing: .hold, spatialCurve: nil)])
        let source = SourceTrimPaths(start: properties[0], end: properties[1], offset: properties[2], mode: .simultaneously)
        #expect(source.isAnimated)
    }

    /// 原始探针不调用生产标量读取器；逐段比较时间/端值及单维ease，空间切线必须为空。
    private func compare(_ property: SourceProperty<Double>, with raw: TrimAuditProperty) throws {
        #expect(property.initialValue == raw.values.first)
        #expect(property.isAnimated == (raw.kinds.isEmpty == false))
        try #require(property.keyframes.count == raw.kinds.count)
        if raw.kinds.isEmpty { return }
        #expect(property.keyframes.map(\.startFrame) == Array(raw.times.dropLast()))
        #expect(property.keyframes.map(\.endFrame) == Array(raw.times.dropFirst()))
        for (index, frame) in property.keyframes.enumerated() {
            #expect(frame.startValue == raw.values[index] && frame.endValue == raw.values[index + 1])
            #expect(frame.spatialCurve == nil)
            switch frame.easing {
            case .linear: #expect(raw.kinds[index] <= 1)
            case .hold: #expect(raw.kinds[index] == 3)
            case .bezier(_, let second): #expect(raw.kinds[index] == 2 && second == nil)
            }
        }
    }
}
