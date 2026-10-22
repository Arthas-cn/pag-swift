import Metal
import Testing
@testable import pag_swift

/// tag85真实字段与所属图层拓扑的调查；尚不把解析成功算作样式播放。
struct PAGGradientOverlayEvidenceTests {
    /// LOGO首中末正式帧须通过公开Loader、FramePlanner与生产Metal的整层样式局部准备。
    @Test func logoFramesPrepareGradientOverlay() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "PAG_LOGO.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let root = try #require(file.storage.compositions.last)
        print("PAG_LOGO_ROOT id=\(root.id) frames=\(root.durationFrames)")
        let size = try PAGSize(width: 256, height: 256)
        let resources = try MetalResources(device: #require(MTLCreateSystemDefaultDevice()))
        var activeOverlayFrames = 0
        for index in Set([Int64(0), root.durationFrames / 2, root.durationFrames - 1]).sorted() {
            let frame = try await FramePlanner.prepare(scene,
                at: SceneValidator.time(frame: index, rate: root.frameRate),
                targetSize: size, scale: 1, mode: .aspectFit)
            let batch = try MetalFramePreparation.prepare(frame, width: 256, height: 256,
                resources: resources, disablePictureCache: true)
            #expect(batch.passes.last?.attachment == nil)
            let overlays = overlayCount(in: batch)
            if overlays > 0 { activeOverlayFrames += 1 }
            print("PAG_LOGO_PREPARED frame=\(index) overlay=\(overlays) draws=\(batch.drawCount)")
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
        #expect(activeOverlayFrames > 0)
    }

    /// Track Matte局部批次可以递归承载样式源；根批次自身为零不代表样式没有准备。
    private func overlayCount(in batch: MetalFrameBatch) -> Int {
        batch.gradientOverlayWorks.count + batch.trackMatteWorks.reduce(0) {
            $0 + overlayCount(in: $1.content) + overlayCount(in: $1.source)
        }
    }

    /// 生产读取器保留唯一动态角度并消费完整真实载荷，正式图层持有样式而不丢字段。
    @Test func logoProductionReaderPreservesAngleAndLayer() throws {
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(PAGFixtures.data(named: "PAG_LOGO.pag"))
        let item = try #require(inspection.effectReaders.first { $0.code == 85 })
        var reader = item.reader
        var decoder = PAGSceneDecoder(limits: .standard,
            budget: DecodeBudget(limit: 64 * 1024 * 1024))
        let style = try decoder.readGradientOverlay(reader: &reader)
        #expect(reader.remainingByteCount == 0)
        #expect(style.blendMode.initialValue == 0)
        #expect(style.opacity.initialValue == 255)
        #expect(style.colors.initialValue.colorStops.count == 2)
        #expect(style.style.initialValue == 2)
        #expect(style.angle.isAnimated)
        #expect(try PropertyEvaluation.scalar(style.angle, at: 0) == 200)
        #expect(try PropertyEvaluation.scalar(style.angle, at: 150) == 90)
        var layer = item.layerReader
        let decoded = try decoder.readLayer(reader: &layer)
        #expect(decoded.gradientOverlay?.supportsAngleWhiteBlack == true)
        #expect(layer.remainingByteCount == 0)
    }

    /// 按上游十项属性顺序完整消费LOGO载荷，记录动态位及绘制所需的实际值。
    @Test func logoGradientOverlayFields() throws {
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(PAGFixtures.data(named: "PAG_LOGO.pag"))
        let items = inspection.effectReaders.filter { $0.code == 85 }
        #expect(!items.isEmpty)
        print("PAG_LOGO_MATTES \(inspection.trackMattePayloads.filter { $0.mode != 0 })")
        for item in items {
            var reader = item.reader
            var decoder = PAGSceneDecoder(limits: .standard,
                budget: DecodeBudget(limit: 64 * 1024 * 1024))
            let flags = try PropertyFlags.read(Array(repeating: .property, count: 9) + [.spatialProperty],
                from: &reader)
            let blend = try decoder.readDiscreteByteProperty(flags[0], defaultValue: 0,
                maximum: 255, reader: &reader)
            let opacity = try decoder.readOpacityProperty(flags[1], reader: &reader)
            let colors = try decoder.readGradientProperty(flags[2], reader: &reader)
            let smoothness = try decoder.readScalarProperty(flags[3], defaultValue: 100, reader: &reader)
            let angle = try decoder.readScalarProperty(flags[4], defaultValue: 90, reader: &reader)
            let style = try decoder.readDiscreteByteProperty(flags[5], defaultValue: 0,
                maximum: 255, reader: &reader)
            let reverse = try decoder.readDiscreteBoolProperty(flags[6], defaultValue: false, reader: &reader)
            let align = try decoder.readDiscreteBoolProperty(flags[7], defaultValue: true, reader: &reader)
            let scale = try decoder.readScalarProperty(flags[8], defaultValue: 100, reader: &reader)
            let offset = try decoder.readPointProperty(flags[9], defaultValue: .zero,
                spatial: true, reader: &reader)
            try StaticAttributes.requireEnd(of: reader)
            let attributes = try #require(item.attributes)
            var attributesReader = attributes.reader
            let layer = try decoder.readLayerAttributes(code: attributes.code, reader: &attributesReader)
            print("PAG_GRADIENT_OVERLAY comp=\(item.compositionID) layer=\(item.layerID) kind=\(item.kind) start=\(layer.start) duration=\(layer.duration) blend=\(blend.initialValue) opacity=\(opacity.initialValue) colors=\(colors.initialValue.colorStops.count)/\(colors.initialValue.alphaStops.count) smoothness=\(smoothness.initialValue) angle=\(angle.initialValue) style=\(style.initialValue) reverse=\(reverse.initialValue) align=\(align.initialValue) scale=\(scale.initialValue) offset=\(offset.initialValue) animated=\(flags.map(\.isAnimated))")
            for frame in [layer.start, layer.start + layer.duration / 2,
                          layer.start + layer.duration - 1] {
                print("PAG_GRADIENT_OVERLAY_FRAME frame=\(frame) angle=\(try PropertyEvaluation.scalar(angle, at: frame))")
            }
            print("PAG_GRADIENT_OVERLAY_STOPS colors=\(colors.initialValue.colorStops) alphas=\(colors.initialValue.alphaStops)")
            var layerReader = item.layerReader
            _ = try layerReader.readUInt8()
            _ = try layerReader.readEncodedUInt32()
            var tags: [UInt16] = []
            while let block = try decoder.nextBlock(from: &layerReader) { tags.append(block.code) }
            print("PAG_GRADIENT_OVERLAY_LAYER_TAGS \(tags)")
        }
    }
}
