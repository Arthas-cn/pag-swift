import Foundation
import Testing
@testable import pag_swift

/// 两份含tag58真实文件的字段与同层效果拓扑调查；尚不开放CornerPin播放。
struct PAGCornerPinEvidenceTests {
    /// 四角Spatial轨道加通用opacity/mask引用必须完整消费并记录所属图层。
    @Test(arguments: ["cornerpin-bulge.pag", "motiontile_text_corner.pag"])
    func realCornerPinPayloads(_ name: String) throws {
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(PAGFixtures.data(named: name))
        let payloads = inspection.effectReaders.filter { $0.code == 58 }
        #expect(!payloads.isEmpty, "file=\(name)")
        for item in payloads {
            var reader = item.reader
            var decoder = PAGSceneDecoder(limits: .standard,
                budget: DecodeBudget(limit: 64 * 1024 * 1024))
            let flags = try PropertyFlags.read([.spatialProperty, .spatialProperty,
                .spatialProperty, .spatialProperty, .property, .flag], from: &reader)
            let upperLeft = try decoder.readPointProperty(flags[0], defaultValue: .zero,
                spatial: true, reader: &reader)
            let upperRight = try decoder.readPointProperty(flags[1], defaultValue: ScenePoint(x: 1280, y: 0),
                spatial: true, reader: &reader)
            let lowerLeft = try decoder.readPointProperty(flags[2], defaultValue: ScenePoint(x: 0, y: 720),
                spatial: true, reader: &reader)
            let lowerRight = try decoder.readPointProperty(flags[3], defaultValue: ScenePoint(x: 1280, y: 720),
                spatial: true, reader: &reader)
            let opacity = try decoder.readOpacityProperty(flags[4], reader: &reader)
            let count = try flags[5].exists ? Int(reader.readEncodedUInt32()) : 0
            #expect(count <= reader.remainingByteCount)
            var masks: [UInt32] = []
            for _ in 0..<count { masks.append(try reader.readEncodedUInt32()) }
            try StaticAttributes.requireEnd(of: reader)
            if ProcessInfo.processInfo.environment["PAG_CORNER_PIN_AUDIT"] == "1" {
                print("PAG_CORNER_PIN file=\(name) comp=\(item.compositionID) layer=\(item.layerID) kind=\(item.kind) animated=\(flags.map(\.isAnimated)) UL=\(upperLeft.initialValue) UR=\(upperRight.initialValue) LL=\(lowerLeft.initialValue) LR=\(lowerRight.initialValue) opacity=\(opacity.initialValue) masks=\(masks)")
                let effects = inspection.effectReaders.filter {
                    $0.compositionID == item.compositionID && $0.layerID == item.layerID
                }.map(\.code)
                print("PAG_CORNER_PIN_CHAIN file=\(name) layer=\(item.layerID) tags=\(effects)")
            }
        }
    }
}
