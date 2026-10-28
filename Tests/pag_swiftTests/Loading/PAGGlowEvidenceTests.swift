import Testing
@testable import pag_swift

/// clip1的真实Glow和FastBlur按上游字段、层组合及绝对帧顺序验证。
struct PAGGlowEvidenceTests {
    /// 层115全部可见源帧的动态平铺、Glow、Bulge均落在保守局部采样范围内。
    @Test func clip1TileGlowBulgeLayoutsForEveryFrame() throws {
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(PAGFixtures.data(named: "nodegroup_clip1.pag"))
        let items = inspection.effectReaders.filter { $0.compositionID == 31 && $0.layerID == 115 }
        let tileItem = try #require(items.first { $0.code == 56 })
        let glowItem = try #require(items.first { $0.code == 61 })
        let bulgeItem = try #require(items.first { $0.code == 59 })
        var decoder = PAGSceneDecoder(limits: .standard,
            budget: DecodeBudget(limit: 64 * 1024 * 1024))
        var tileReader = tileItem.reader
        let tileSource = try decoder.readMotionTile(reader: &tileReader)
        try StaticAttributes.requireEnd(of: tileReader)
        var glowReader = glowItem.reader
        let glowSource = try decoder.readGlow(reader: &glowReader)
        try StaticAttributes.requireEnd(of: glowReader)
        var bulgeReader = bulgeItem.reader
        let bulgeSource = try decoder.readBulge(reader: &bulgeReader)
        try StaticAttributes.requireEnd(of: bulgeReader)
        let attribute = try #require(tileItem.attributes)
        var attributeReader = attribute.reader
        let layer = try decoder.readLayerAttributes(code: attribute.code, reader: &attributeReader)
        let size = try PAGSize(width: 720, height: 1280)
        let clip = FrameClip(size: size, matrix: .identity)
        let visible = try RenderBounds(left: 0, top: 0, right: 720, bottom: 1280)
        var active = 0, checked = 0, largestArea = 0
        for frame in layer.start..<(layer.start + layer.duration) {
            let tile = try FrameMotionTile(tileSource.value(at: frame), compositionSize: size)
            let glow = try glowSource.value(at: frame)
            let bulge = try bulgeSource.value(at: frame)
            let layout = try #require(try TileGlowBulgeLayout(clip: clip, tile: tile,
                glow: glow, bulge: bulge, visible: visible))
            let grid = try MappedGlowGrid(layout: layout, glow: glow)
            #expect(layout.sample.width < 2160)
            #expect(layout.sample.height < 3840)
            #expect(grid.horizontal.width < Int(grid.sampling.blurWidth))
            #expect(grid.vertical.height < Int(grid.sampling.blurHeight))
            let effectBytes = 4 * (layout.sample.width * layout.sample.height
                + grid.horizontal.width * grid.horizontal.height
                + grid.vertical.width * grid.vertical.height)
            #expect(effectBytes < 64 * 1024 * 1024)
            if bulge != nil { active += 1 }
            checked += 1
            largestArea = max(largestArea, layout.sample.width * layout.sample.height)
        }
        #expect(active > 0)
        #expect(checked == layer.duration)
        print("PAG_TILE_GLOW_BULGE_LAYOUT active=\(active) total=\(checked) largestArea=\(largestArea)")
    }

    /// 层115正式读取器消费全部tag56→61→59字段，并按已证实的三段顺序保留效果。
    @Test func clip1TileGlowBulgeReadsFullChain() throws {
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(PAGFixtures.data(named: "nodegroup_clip1.pag"))
        let item = try #require(inspection.effectReaders.first {
            $0.compositionID == 31 && $0.layerID == 115 && $0.code == 56
        })
        var reader = item.layerReader
        var decoder = PAGSceneDecoder(limits: .standard,
            budget: DecodeBudget(limit: 64 * 1024 * 1024))
        let layer = try decoder.readLayer(reader: &reader)
        #expect(layer.motionTile != nil)
        #expect(layer.glow != nil)
        #expect(layer.bulge != nil)
        #expect(reader.remainingByteCount == 0)
    }

    /// 原始合成标签给出三条真实效果层的内容尺寸与引用路径，不用显示裁剪猜输入范围。
    @Test func clip1EffectCompositionInputs() throws {
        var decoder = PAGSceneDecoder(limits: .standard,
            budget: DecodeBudget(limit: 64 * 1024 * 1024))
        var file = PAGByteReader(data: try PAGFixtures.data(named: "nodegroup_clip1.pag"))
        try file.skip(byteCount: 9)
        var sizes: [UInt32: PAGSize] = [:]
        var references: [(owner: UInt32, layer: UInt32, child: UInt32, start: Int64)] = []
        while var composition = try decoder.nextBlock(from: &file) {
            guard composition.code == 2 else { continue }
            let owner = try composition.reader.readEncodedUInt32()
            while var block = try decoder.nextBlock(from: &composition.reader) {
                switch block.code {
                case 3:
                    sizes[owner] = try decoder.readCompositionAttributes(reader: &block.reader).size
                case 5:
                    _ = try block.reader.readUInt8()
                    let layer = try block.reader.readEncodedUInt32()
                    while var child = try decoder.nextBlock(from: &block.reader) {
                        guard child.code == 12 else { continue }
                        let target = try child.reader.readEncodedUInt32()
                        let start = try StaticAttributes.frame(from: &child.reader)
                        try StaticAttributes.requireEnd(of: child.reader)
                        references.append((owner, layer, target, start))
                    }
                default: break
                }
            }
        }
        let targets = references.filter { $0.owner == 31 && [115, 132, 149].contains($0.layer) }
        #expect(targets.count == 3)
        #expect(targets.allSatisfy { sizes[$0.child] != nil })
        print("PAG_EFFECT_INPUTS comp31=\(String(describing: sizes[31])) targets=\(targets) childSizes=\(targets.map { String(describing: sizes[$0.child]) }) parents=\(references.filter { $0.child == 31 })")
    }

    /// 两个真实FastBlur层的父链与二维变换决定滤镜源缩放，不能只用最终显示宽高代替。
    @Test func clip1FastBlurLayerTransforms() throws {
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(PAGFixtures.data(named: "nodegroup_clip1.pag"))
        let items = inspection.effectReaders.filter { $0.code == 60 && [132, 149].contains($0.layerID) }
        #expect(items.count == 2)
        for item in items {
            var reader = try #require(item.transform)
            var decoder = PAGSceneDecoder(limits: .standard,
                budget: DecodeBudget(limit: 64 * 1024 * 1024))
            let source = try decoder.readTransform(reader: &reader)
            try StaticAttributes.requireEnd(of: reader)
            let attributes = try #require(item.attributes)
            var attributeReader = attributes.reader
            let layer = try decoder.readLayerAttributes(code: attributes.code, reader: &attributeReader)
            let frames = [layer.start, layer.start + layer.duration / 2,
                          layer.start + layer.duration - 1]
            for frame in frames {
                let value = try source.value(at: frame)
                let evaluated = try TransformEvaluation.layer(value)
                let matrix = evaluated.matrix
                #expect(matrix.a.isFinite && matrix.b.isFinite && matrix.c.isFinite && matrix.d.isFinite)
                print("PAG_FAST_BLUR_TRANSFORM layer=\(item.layerID) frame=\(frame) parent=\(String(describing: layer.parentID)) matrix=\(matrix)")
            }
        }
    }

    /// 两条真实预合成层均按Glow→FastBlur顺序完整解码，保留两种边缘模式。
    @Test func clip1GlowLayersPreserveFastBlur() throws {
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(PAGFixtures.data(named: "nodegroup_clip1.pag"))
        let items = inspection.effectReaders.filter { $0.code == 61 && [132, 149].contains($0.layerID) }
        #expect(items.count == 2)
        for item in items {
            var reader = item.layerReader
            var decoder = PAGSceneDecoder(limits: .standard,
                budget: DecodeBudget(limit: 64 * 1024 * 1024))
            let layer = try decoder.readLayer(reader: &reader)
            #expect(layer.glow != nil)
            #expect(layer.fastBlur != nil)
            #expect(layer.fastBlur?.repeatEdgePixels.initialValue == (item.layerID == 132))
        }
        print("PAG_GLOW_COMPLETE_ORDER \(inspection.effectReaders.filter { $0.compositionID == 31 }.map { "\($0.layerID):\($0.code)" })")
    }

    /// FastBlur的五条属性按上游tag60有界读取，记录真实层顺序与初值。
    @Test func clip1FastBlurFields() throws {
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(PAGFixtures.data(named: "nodegroup_clip1.pag"))
        let items = inspection.effectReaders.filter { $0.code == 60 }
        #expect(!items.isEmpty)
        for item in items {
            var reader = item.reader
            var decoder = PAGSceneDecoder(limits: .standard,
                budget: DecodeBudget(limit: 64 * 1024 * 1024))
            let flags = try PropertyFlags.read([.property, .property, .property, .property, .flag],
                from: &reader)
            let blur = try decoder.readScalarProperty(flags[0], defaultValue: 0, reader: &reader)
            let direction = try decoder.readDiscreteByteProperty(flags[1], defaultValue: 0,
                maximum: 2, reader: &reader)
            let repeatEdge = try decoder.readDiscreteBoolProperty(flags[2], defaultValue: false,
                reader: &reader)
            let opacity = try decoder.readOpacityProperty(flags[3], reader: &reader)
            let count = try flags[4].exists ? Int(reader.readEncodedUInt32()) : 0
            #expect(count <= reader.remainingByteCount)
            for _ in 0..<count { _ = try reader.readEncodedUInt32() }
            try StaticAttributes.requireEnd(of: reader)
            let attribute = try #require(item.attributes)
            var attributesReader = attribute.reader
            let layer = try decoder.readLayerAttributes(code: attribute.code, reader: &attributesReader)
            let values = try (layer.start..<(layer.start + min(layer.duration, 300))).map {
                try PropertyEvaluation.scalar(blur, at: $0)
            }
            var formalReader = item.reader
            var formalDecoder = PAGSceneDecoder(limits: .standard,
                budget: DecodeBudget(limit: 64 * 1024 * 1024))
            let formal = try formalDecoder.readFastBlur(reader: &formalReader)
            #expect(formalReader.remainingByteCount == 0)
            #expect(formal.blurriness.isAnimated == blur.isAnimated)
            #expect(formal.direction.initialValue == direction.initialValue)
            #expect(formal.repeatEdgePixels.initialValue == repeatEdge.initialValue)
            for (offset, value) in values.enumerated() {
                let sampled = try formal.value(at: layer.start + Int64(offset))
                #expect(sampled.blurriness == value)
                #expect(sampled.direction == 0)
                #expect(sampled.repeatEdgePixels == repeatEdge.initialValue)
            }
            let nonzero = values.enumerated().filter { $0.element != 0 }.map(\.offset)
            print("PAG_FAST_BLUR comp=\(item.compositionID) layer=\(item.layerID) start=\(layer.start) duration=\(layer.duration) blur=\(blur.initialValue) range=\(values.min() ?? 0)...\(values.max() ?? 0) activeFrames=\(nonzero.count) firstActive=\(String(describing: nonzero.first)) direction=\(direction.initialValue) repeat=\(repeatEdge.initialValue) opacity=\(opacity.initialValue) masks=\(count) animated=\(flags.map(\.isAnimated))")
        }
    }

    /// 三个真实预合成层的Glow轨道经正式字段读取器完整消费，动画值仍能按帧求取。
    @Test func clip1GlowDecoderPreservesTracks() throws {
        var inspection = ShapeAnimationInspection()
        try inspection.inspect(PAGFixtures.data(named: "nodegroup_clip1.pag"))
        let items = inspection.effectReaders.filter { $0.code == 61 }
        #expect(Set(items.map(\.layerID)) == Set<UInt32>([115, 132, 149]))
        for item in items {
            var reader = item.reader
            var decoder = PAGSceneDecoder(limits: .standard,
                budget: DecodeBudget(limit: 64 * 1024 * 1024))
            let glow = try decoder.readGlow(reader: &reader)
            #expect(reader.remainingByteCount == 0)
            #expect(glow.threshold.isAnimated)
            #expect(glow.radius.isAnimated)
            #expect(glow.intensity.isAnimated == (item.layerID == 132))
            #expect(glow.intensity.initialValue == 1)
            let attribute = try #require(item.attributes)
            var attributesReader = attribute.reader
            let layer = try decoder.readLayerAttributes(code: attribute.code, reader: &attributesReader)
            // 属性轨道使用所属合成绝对帧，不能把层内偏移0误当文件帧0。
            for frame in [layer.start, layer.start + layer.duration / 2,
                          layer.start + layer.duration - 1] {
                let sampled = try glow.value(at: frame)
                #expect(sampled.threshold.isFinite)
                #expect(sampled.radius.isFinite)
                #expect(sampled.intensity.isFinite)
            }
        }
    }

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
