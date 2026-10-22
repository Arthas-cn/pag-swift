import Foundation
import Testing
@testable import pag_swift

/// 唯一tag27真实文件按RoundCornersTag的SimpleProperty<Float>检查半径轨道。
struct PAGRoundCornersEvidenceTests {
    /// 原样子流完整消费并记录首值与段数，不把发现tag误报为已经实现圆角几何。
    @Test func realRoundCornerRadius() throws {
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(PAGFixtures.data(named: "wstask_prizebaoji.pag"))
        #expect(!inspection.roundCornersReaders.isEmpty)
        for input in inspection.roundCornersReaders {
            var reader = input
            let flags = try PropertyFlags.read([.property], from: &reader)
            var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 64 * 1024 * 1024))
            let radius = try decoder.readScalarProperty(flags[0], defaultValue: 10, reader: &reader)
            try StaticAttributes.requireEnd(of: reader)
            if ProcessInfo.processInfo.environment["PAG_ROUND_CORNERS_AUDIT"] == "1" {
                print("PAG_ROUND_CORNERS initial=\(radius.initialValue) segments=\(radius.keyframes.count)")
            }
        }
        if ProcessInfo.processInfo.environment["PAG_ROUND_CORNERS_AUDIT"] == "1" {
            print("PAG_ROUND_CORNERS groups=\(inspection.roundCornerGroups)")
        }
    }
}
