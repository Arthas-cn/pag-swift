import Foundation
import Testing
@testable import pag_swift

/// 图像、文本及clip1预合成层的真实tag59字段调查，独立于支持范围判断。
struct PAGBulgeEvidenceTests {
    /// 八项flags与后续值必须在各自子流内完整消费，不能凭效果名称猜半径或pinning。
    @Test(arguments: ["Bulge-unpin-s.pag", "bulgetext.pag", "cornerpin-bulge.pag",
                      "nodegroup_clip1.pag",
                      "text1.pag", "text2.pag", "text3.pag", "text4.pag"])
    func realBulgePayloads(_ name: String) throws {
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(PAGFixtures.data(named: name))
        let payloads = inspection.effectReaders.filter { $0.code == 59 }
        #expect(!payloads.isEmpty, "file=\(name)")
        for item in payloads {
            var reader = item.reader
            var decoder = PAGSceneDecoder(limits: .standard,
                budget: DecodeBudget(limit: 64 * 1024 * 1024))
            // 六项几何轨道之后才是通用effectOpacity和自定义mask引用。
            let flags = try PropertyFlags.read([.property, .property, .spatialProperty,
                .property, .property, .property, .property, .flag], from: &reader)
            let horizontal = try decoder.readScalarProperty(flags[0], defaultValue: 50, reader: &reader)
            let vertical = try decoder.readScalarProperty(flags[1], defaultValue: 50, reader: &reader)
            let center = try decoder.readPointProperty(flags[2], defaultValue: ScenePoint(x: 640, y: 360),
                spatial: true, reader: &reader)
            let height = try decoder.readScalarProperty(flags[3], defaultValue: 1, reader: &reader)
            let taper = try decoder.readScalarProperty(flags[4], defaultValue: 0, reader: &reader)
            let pinning = try decoder.readDiscreteBoolProperty(flags[5], defaultValue: false, reader: &reader)
            let opacity = try decoder.readOpacityProperty(flags[6], reader: &reader)
            let count = try flags[7].exists ? Int(reader.readEncodedUInt32()) : 0
            #expect(count <= reader.remainingByteCount, "file=\(name)")
            var masks: [UInt32] = []
            for _ in 0..<count { masks.append(try reader.readEncodedUInt32()) }
            try StaticAttributes.requireEnd(of: reader)
            if ProcessInfo.processInfo.environment["PAG_BULGE_AUDIT"] == "1" {
                print("PAG_BULGE file=\(name) comp=\(item.compositionID) layer=\(item.layerID) kind=\(item.kind) animated=\(flags.map(\.isAnimated)) radius=\(horizontal.initialValue),\(vertical.initialValue) center=\(center.initialValue) height=\(height.initialValue) taper=\(taper.initialValue) pin=\(pinning.initialValue) opacity=\(opacity.initialValue) masks=\(masks)")
            }
        }
    }
}
