import Foundation
import Testing
@testable import pag_swift

/// 三份因非默认图层blend门禁失败的真实文件，记录其原始值和所属层种类。
struct PAGBlendModeEvidenceTests {
    /// 每份至少一条BlendMode值，原始字节不按现有Normal行为消耗后忽略。
    @Test(arguments: ["nodegroup_clip1.pag", "nodegroup_clip2.pag", "tougao.pag"])
    func realLayerBlendModes(_ name: String) throws {
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(PAGFixtures.data(named: name))
        #expect(!inspection.blendModePayloads.isEmpty, "file=\(name)")
        if ProcessInfo.processInfo.environment["PAG_BLEND_AUDIT"] == "1" {
            for item in inspection.blendModePayloads {
                print("PAG_BLEND file=\(name) comp=\(item.compositionID) layer=\(item.layerID) kind=\(item.layerKind) mode=\(item.mode)")
            }
        }
    }
}
