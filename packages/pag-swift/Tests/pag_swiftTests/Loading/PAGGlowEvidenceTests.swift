import Testing
@testable import pag_swift

/// clip1的tag61独立按上游GlowEffectTag字段读取，不从标签名称推断效果为空。
struct PAGGlowEvidenceTests {
    /// 完整消费阈值、半径、强度和合成选项，定位所属层与动态范围。
    @Test func clip1GlowFields() throws {
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(PAGFixtures.data(named: "nodegroup_clip1.pag"))
        let items = inspection.effectReaders.filter { $0.code == 61 }
        #expect(!items.isEmpty)
        print("PAG_GLOW_ORDER \(inspection.effectReaders.filter { $0.compositionID == 31 }.map { "\($0.layerID):\($0.code)" })")
        for item in items {
            var reader = item.reader
            let flags = try PropertyFlags.read([.property, .property, .property, .property, .flag],
                from: &reader)
            var decoder = PAGSceneDecoder(limits: .standard,
                budget: DecodeBudget(limit: 64 * 1024 * 1024))
            let threshold = try decoder.readScalarProperty(flags[0], defaultValue: 1, reader: &reader)
            let radius = try decoder.readScalarProperty(flags[1], defaultValue: 100, reader: &reader)
            let intensity = try decoder.readScalarProperty(flags[2], defaultValue: 0, reader: &reader)
            let opacity = try decoder.readOpacityProperty(flags[3], reader: &reader)
            let count = try flags[4].exists ? Int(reader.readEncodedUInt32()) : 0
            #expect(count <= reader.remainingByteCount)
            var masks: [UInt32] = []
            for _ in 0..<count { masks.append(try reader.readEncodedUInt32()) }
            try StaticAttributes.requireEnd(of: reader)
            print("PAG_GLOW comp=\(item.compositionID) layer=\(item.layerID) kind=\(item.kind) threshold=\(threshold.initialValue) radius=\(radius.initialValue) intensity=\(intensity.initialValue) opacity=\(opacity.initialValue) masks=\(masks) animated=\(flags.map(\.isAnimated))")
        }
    }
}
