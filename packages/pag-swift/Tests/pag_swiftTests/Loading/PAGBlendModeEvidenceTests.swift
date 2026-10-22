import Foundation
import Testing
@testable import pag_swift

/// 三份因非默认图层blend门禁失败的真实文件，记录其原始值和所属层种类。
struct PAGBlendModeEvidenceTests {
    /// tougao同一Shape层同时含FastBlur和HardLight，Loader须完整保留两个语义字段。
    @Test func tougaoCombinedChainLoadsBothEffects() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "tougao.pag"))
        let layer = try #require(file.storage.compositions
            .flatMap(\.layers).first(where: { $0.id == 389 }))
        #expect(layer.blendMode == .hardLight)
        #expect(layer.fastBlur != nil)
    }

    /// tougao同一层的tag60全部73帧为All/Decal动态模糊，不能与HardLight拆成两层。
    @Test func tougaoHardLightAndBlurRawBoundary() throws {
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(PAGFixtures.data(named: "tougao.pag"))
        #expect(inspection.blendModePayloads.contains {
            $0.compositionID == 2 && $0.layerID == 389 && $0.layerKind == 4 && $0.mode == 8
        })
        let blurLayers = inspection.effectReaders.filter { $0.code == 60 }
        #expect(blurLayers.count == 1)
        let item = try #require(blurLayers.first)
        #expect(item.compositionID == 2 && item.layerID == 389 && item.kind == 4)
        var reader = item.reader
        var decoder = PAGSceneDecoder(limits: .standard,
            budget: DecodeBudget(limit: 64 * 1024 * 1024))
        let blur = try decoder.readFastBlur(reader: &reader)
        let attributes = try #require(item.attributes)
        var attributesReader = attributes.reader
        let layer = try decoder.readLayerAttributes(code: attributes.code, reader: &attributesReader)
        let values = try (layer.start..<(layer.start + min(layer.duration, 300))).map {
            try blur.value(at: $0)
        }
        let active = values.filter { $0.blurriness > 0 }
        print("PAG_TOUGAO_FAST_BLUR frames=\(values.count) active=\(active.count) max=\(active.map(\.blurriness).max() ?? 0) repeat=\(Set(values.map(\.repeatEdgePixels))) directions=\(Set(values.map(\.direction)))")
        if var transformReader = item.transform {
            let transform = try decoder.readTransform(reader: &transformReader)
            let first = try transform.value(at: layer.start)
            let last = try transform.value(at: layer.start + layer.duration - 1)
            print("PAG_TOUGAO_TRANSFORM first=\(first) last=\(last)")
        }
    }

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
