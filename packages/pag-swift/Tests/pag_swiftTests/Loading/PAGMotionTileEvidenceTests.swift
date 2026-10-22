import Foundation
import Testing
@testable import pag_swift

/// tag56五份真实文件的完整字段与动画标记调查；此测试不代表效果已可播放。
struct PAGMotionTileEvidenceTests {
    /// 按MotionTileEffectTag的十项配置读取有界载荷，确认动画和mask引用没有错位。
    @Test(arguments: ["MT2.pag", "motiontile1.pag", "motiontile_text_corner.pag",
                      "nodegroup_clip1.pag", "nodegroup_clip2.pag"])
    func realMotionTilePayloads(_ name: String) throws {
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(PAGFixtures.data(named: name))
        let payloads = inspection.effectReaders.filter { $0.code == 56 }
        #expect(!payloads.isEmpty, "file=\(name)")
        for item in payloads {
            var reader = item.reader
            var decoder = PAGSceneDecoder(limits: .standard,
                budget: DecodeBudget(limit: 64 * 1024 * 1024))
            // 上游先读取八项效果Property，再读取opacity与自定义mask列表的两项标志。
            let flags = try PropertyFlags.read([.spatialProperty, .property, .property,
                .property, .property, .property, .property, .property, .property, .flag],
                from: &reader)
            let center = try decoder.readPointProperty(flags[0],
                defaultValue: ScenePoint(x: 640, y: 360), spatial: true, reader: &reader)
            let width = try decoder.readScalarProperty(flags[1], defaultValue: 100, reader: &reader)
            let height = try decoder.readScalarProperty(flags[2], defaultValue: 100, reader: &reader)
            let outputWidth = try decoder.readScalarProperty(flags[3], defaultValue: 100, reader: &reader)
            let outputHeight = try decoder.readScalarProperty(flags[4], defaultValue: 100, reader: &reader)
            let mirror = try decoder.readDiscreteBoolProperty(flags[5], defaultValue: false, reader: &reader)
            let phase = try decoder.readScalarProperty(flags[6], defaultValue: 0, reader: &reader)
            let horizontal = try decoder.readDiscreteBoolProperty(flags[7], defaultValue: false, reader: &reader)
            let opacity = try decoder.readOpacityProperty(flags[8], reader: &reader)
            let count = try flags[9].exists ? Int(reader.readEncodedUInt32()) : 0
            #expect(count <= reader.remainingByteCount, "file=\(name)")
            var masks: [UInt32] = []
            for _ in 0..<count { masks.append(try reader.readEncodedUInt32()) }
            try StaticAttributes.requireEnd(of: reader)
            if ProcessInfo.processInfo.environment["PAG_MOTION_TILE_AUDIT"] == "1" {
                var transformDescription = "missing"
                if var transformReader = item.transform {
                    let value = try decoder.readTransform(reader: &transformReader)
                    try StaticAttributes.requireEnd(of: transformReader)
                    transformDescription = "anchor=\(value.anchor.initialValue),position=\(value.position),scale=\(value.scale.initialValue),rotation=\(value.rotation.initialValue)"
                }
                print("PAG_MOTION_TILE file=\(name) comp=\(item.compositionID) layer=\(item.layerID) kind=\(item.kind) animated=\(flags.map(\.isAnimated)) center=\(center.initialValue) width=\(width.initialValue) height=\(height.initialValue) output=\(outputWidth.initialValue),\(outputHeight.initialValue) mirror=\(mirror.initialValue) phase=\(phase.initialValue) horizontal=\(horizontal.initialValue) opacity=\(opacity.initialValue) masks=\(masks) transform=\(transformDescription)")
            }
        }
    }
}
