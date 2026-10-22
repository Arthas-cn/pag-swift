import Foundation
import Testing
@testable import pag_swift

/// 两份Screen预合成被tag57挡住后，独立读取真实Levels Individual字段。
struct PAGLevelsIndividualEvidenceTests {
    /// 按上游二十条SimpleProperty和通用合成选项完整消费，不把原始效果误当默认值。
    @Test(arguments: ["nodegroup_clip1.pag", "nodegroup_clip2.pag"])
    func realLevelsPayloads(_ name: String) throws {
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(PAGFixtures.data(named: name))
        let items = inspection.effectReaders.filter { $0.code == 57 }
        #expect(!items.isEmpty)
        print("PAG_SCREEN_EFFECT_ORDER file=\(name) values=\(inspection.effectReaders.filter { $0.compositionID == 31 }.map { "\($0.layerID):\($0.code)" })")
        for item in items {
            var reader = item.reader
            let defaults: [Double] = [0, 255, 1, 0, 255]
            let flags = try PropertyFlags.read(Array(repeating: AttributeEncoding.property, count: 21) + [.flag],
                from: &reader)
            var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 64 * 1024 * 1024))
            var values: [Double] = []
            for index in 0..<20 {
                let value = try decoder.readScalarProperty(flags[index], defaultValue: defaults[index % 5], reader: &reader)
                #expect(!value.isAnimated)
                values.append(value.initialValue)
            }
            let opacity = try decoder.readOpacityProperty(flags[20], reader: &reader)
            let count = try flags[21].exists ? Int(reader.readEncodedUInt32()) : 0
            for _ in 0..<count { _ = try reader.readEncodedUInt32() }
            try StaticAttributes.requireEnd(of: reader)
            print("PAG_LEVELS file=\(name) comp=\(item.compositionID) layer=\(item.layerID) kind=\(item.kind) values=\(values) opacity=\(opacity.initialValue) masks=\(count)")
        }
    }

    /// clip2的tag63已进入相邻矩阵采样；clip1继续被独立的Glow tag61明确拒绝。
    @Test func clip2DecodesAndClip1StopsAtGlow() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "nodegroup_clip2.pag"))
        #expect(file.composition.layers.contains { $0.kind == .precomposition })
        await #expect(throws: PAGError.unsupportedFeature("layerTag:61")) {
            try await PAGLoader().load(data: PAGFixtures.data(named: "nodegroup_clip1.pag"))
        }
    }
}
