import Foundation
import Testing
@testable import pag_swift

/// 五份tag63真实文件的名称与运动模糊位按上游LayerAttributesExtra字段独立核对。
struct PAGLayerExtraEvidenceTests {
    /// 2J的动态MotionBlur只包预合成内容，MT2的同一开关则在图像MotionTile之后生效。
    @Test func remainingMotionBlurLayersHaveDistinctInputChains() throws {
        var twoJ = ShapeAnimationInspection()
        try twoJ.inspect(PAGFixtures.data(named: "2J.pag"))
        let precomposition = try #require(twoJ.layerExtraReaders.first {
            $0.compositionID == 556 && $0.layerID == 568
        })
        #expect(precomposition.kind == 6)
        #expect(twoJ.effectReaders.filter { $0.compositionID == 556 && $0.layerID == 568 }.isEmpty)
        var mt2 = ShapeAnimationInspection()
        try mt2.inspect(PAGFixtures.data(named: "MT2.pag"))
        let image = try #require(mt2.layerExtraReaders.first {
            $0.compositionID == 1131354197 && $0.layerID == 1131354215
        })
        #expect(image.kind == 5)
        #expect(mt2.effectReaders.filter {
            $0.compositionID == 1131354197 && $0.layerID == 1131354215
        }.map(\.code) == [56])
    }

    /// 有界子流均完整消费；是否启用运动模糊由位标记证明，不由标签存在猜测。
    @Test(arguments: ["2J.pag", "MT2.pag", "TextAnimatorX7.pag",
                      "nodegroup_clip1.pag", "nodegroup_clip2.pag"])
    func layerExtraFieldValues(_ name: String) throws {
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(PAGFixtures.data(named: name))
        #expect(!inspection.layerExtraReaders.isEmpty, "file=\(name)")
        for item in inspection.layerExtraReaders {
            var reader = item.reader
            let flags = try PropertyFlags.read([.flag, .flag], from: &reader)
            let layerName = try flags[0].exists ? reader.readUTF8String() : ""
            try StaticAttributes.requireEnd(of: reader)
            var transformSummary = "missing"
            var parentSummary = "missing"
            if var transformReader = item.transform {
                var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 64 * 1024 * 1024))
                let transform = try decoder.readTransform(reader: &transformReader)
                try StaticAttributes.requireEnd(of: transformReader)
                let positionAnimated: Bool
                switch transform.position {
                case .combined(let value): positionAnimated = value.isAnimated
                case .separated(let x, let y): positionAnimated = x.isAnimated || y.isAnimated
                }
                transformSummary = "anchor:\(transform.anchor.isAnimated),position:\(positionAnimated),scale:\(transform.scale.isAnimated),rotation:\(transform.rotation.isAnimated)"
            }
            if let attributes = item.attributes {
                var reader = attributes.reader
                var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 64 * 1024 * 1024))
                let value = try decoder.readLayerAttributes(code: attributes.code, reader: &reader)
                try StaticAttributes.requireEnd(of: reader)
                parentSummary = value.parentID.map(String.init) ?? "none"
            }
            if ProcessInfo.processInfo.environment["PAG_LAYER_EXTRA_AUDIT"] == "1" {
                print("PAG_LAYER_EXTRA file=\(name) composition=\(item.compositionID) layer=\(item.layerID) kind=\(item.kind) name=\(layerName) parent=\(parentSummary) motionBlur=\(flags[1].exists) transform=\(transformSummary)")
            }
        }
    }

    /// 静态且无父层的tag63滤镜在上游每帧跳过，名称仍必须覆盖旧属性缺省值。
    @Test func staticMotionBlurFlagKeepsExtraName() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "TextAnimatorX7.pag"))
        let layer = try #require(file.storage.compositions.flatMap(\.layers).first { $0.id == 379 })
        #expect(layer.name == "I SEE IT IN YOUR CLOSED EYES TURNING IN")
    }

    /// 两份动态层正式载入后，其效果输入仍分别为预合成紧界与完整图像平铺域。
    @Test func remainingMotionBlurDecoderBoundary() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "2J.pag"))
        let layer = try #require(file.storage.compositions.flatMap(\.layers).first { $0.id == 568 })
        #expect(layer.motionBlur)
        let tiled = try await PAGLoader().load(data: PAGFixtures.data(named: "MT2.pag"))
        let imageLayer = try #require(tiled.storage.compositions.flatMap(\.layers).first { $0.id == 1131354215 })
        #expect(imageLayer.motionBlur)
        guard case .image(let imageID) = imageLayer.content else {
            Issue.record("MT2动态层应为图像")
            return
        }
        let source = try #require(tiled.storage.resources.images[imageID])
        let expected = try PAGSize(width: 858, height: 1250)
        #expect(source.logicalSize == expected)
        #expect(source.image.size == source.logicalSize)
        #expect(source.scaleFactor == 1 && source.anchor.x == 0 && source.anchor.y == 0)
    }
}
