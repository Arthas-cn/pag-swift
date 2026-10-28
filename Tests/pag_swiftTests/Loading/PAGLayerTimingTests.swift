import Foundation
import Testing
@testable import pag_swift

/// LayerAttributes中的时间元数据；不把其轨道误认为图片替换或预合成的播放时钟。
struct PAGLayerTimingTests {
    /// 真实预合成层属性保留400/400原始比例和一段Float32 Bezier轨道，完整消费属性块。
    @Test func readsRealLayerTimeMetadata() throws {
        let layer = try decode(realPayload())
        #expect(layer.name == "Dash Lines Comp" && layer.duration == 110)
        #expect(layer.timing.stretchNumerator == 400 && layer.timing.stretchDenominator == 400)
        let property = layer.timing.timeRemap
        let keyframe = try #require(property.keyframes.first)
        #expect(property.keyframes.count == 1 && keyframe.startFrame == 0 && keyframe.endFrame == 110)
        #expect(keyframe.startValue == 0 && keyframe.endValue == Double(Float(bitPattern: 0x3faa9fbe)))
        guard case .bezier = keyframe.easing else {
            Issue.record("真实时间轨道必须保留Bezier，不能当作默认或线性")
            return
        }
        #expect(try PropertyEvaluation.scalar(property, at: 0) == 0)
        #expect(try PropertyEvaluation.scalar(property, at: 110) == keyframe.endValue)
    }

    /// 三版本缺失时均保存1/1与常量零；显式常量按Float32读取而不是Frame编码。
    @Test(arguments: [UInt16(6), 52, 62])
    func readsDefaultsAndConstants(_ version: UInt16) throws {
        let missing = version == 6 ? [UInt8(1), 30] : [UInt8(1), 0, 30]
        let original = try fragment(missing, version: version)
        #expect(original.timing.stretchNumerator == 1 && original.timing.stretchDenominator == 1)
        #expect(!original.timing.timeRemap.isAnimated && original.timing.timeRemap.initialValue == 0)
        // LayerAttributes的Property存在位/动画位在整块flags中；V3另有motionBlur位。
        let flags: [UInt8] = version == 62 ? [1, 1] : [0x81, 0]
        let explicit = try fragment(flags + [0, 0, 0xa0, 0x3f, 30], version: version)
        #expect(!explicit.timing.timeRemap.isAnimated && explicit.timing.timeRemap.initialValue == 1.25)
    }

    /// 三版本的Linear/Hold轨道消费共同关键帧布局；中点插值和端点保持符合原属性语义。
    @Test(arguments: [UInt16(6), 52, 62], [UInt8(1), 3])
    func readsAnimatedProperties(_ version: UInt16, _ kind: UInt8) throws {
        let flags: [UInt8] = version == 62 ? [1, 3] : [0x81, 1]
        // 一段[0,30]、两个Float32值1.5/2.5、无Bezier控制点的bitWidth及层时长。
        let payload = flags + [1, kind, 0, 30, 0, 0, 0xc0, 0x3f, 0, 0, 0x20, 0x40, 0, 30]
        let property = try fragment(payload, version: version).timing.timeRemap
        #expect(property.isAnimated)
        #expect(try PropertyEvaluation.scalar(property, at: 15) == (kind == 3 ? 1.5 : 2))
        #expect(try PropertyEvaluation.scalar(property, at: 30) == 2.5)
    }

    /// 非默认、负和零分子保存原值，零分母拒绝，不对原始比例擅自约分或赋予速度含义。
    @Test func preservesRatiosAndRejectsZeroDenominator() throws {
        // 独立字段的有符号编码：4→2，3→-1，0→0；分母是无符号原值。
        for (encoded, value) in [(UInt8(4), Int32(2)), (3, -1), (0, 0)] {
            let layer = try fragment([9, 0, encoded, 2, 30])
            #expect(layer.timing.stretchNumerator == value && layer.timing.stretchDenominator == 2)
        }
        #expect(throws: SceneValidator.invalid("zeroLayerStretchDenominator")) {
            try fragment([9, 0, 2, 0, 30])
        }
    }

    /// 真实属性块任意字节截断、NaN、空轨道、预算不足及取消均不返回部分属性结果。
    @Test func rejectsDamageBudgetAndCancellation() async throws {
        let payload = try realPayload()
        for count in 0..<payload.count {
            #expect(throws: PAGError.self) { try decode(Data(payload.prefix(count))) }
        }
        var nonfinite = payload
        nonfinite.replaceSubrange(14..<18, with: [0, 0, 0xc0, 0x7f])
        #expect(throws: PAGError.invalidFile(reason: "nonfiniteScalar", offset: 14)) { try decode(nonfinite) }
        var empty = payload
        empty[6] = 0
        #expect(throws: SceneValidator.invalid("emptyKeyframes")) { try decode(empty) }
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) { try decode(payload, budget: 255) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try decode(payload) }
        }
        await task.value
    }

    /// 层元数据不改共同采样路径；预合成和图片层均带原始轨道时首/中/末仍按源帧推进。
    @Test func metadataDoesNotRetimeCompositionOrImage() async throws {
        let timing = try decode(realPayload()).timing
        let input = try await PAGImage.load(data: PAGFixtures.data(named: "media/rgba-corners.png"))
        let image = SourceImage(id: 1, image: input, logicalSize: input.size, scaleFactor: 1, anchor: .zero)
        let child = try SceneFixtures.composition(1, layers: [timedLayer(10, content: .image(1), timing: timing)])
        let parent = try SceneFixtures.composition(2, layers: [timedLayer(20, content: .precomposition(id: 1, startFrame: 0), timing: timing)])
        let file = try SceneFixtures.build([child, parent], resources: SourceResources(images: [1: image]))
        let scene = try await PreparedScene.prepare(file.composition)
        for index: Int64 in [0, 15, 29] {
            let time = try SceneValidator.time(frame: index, rate: 30)
            let prepared = try await FramePlanner.prepare(scene, at: time, targetSize: file.composition.size, scale: 1, mode: .none)
            let images = prepared.plan.commands.compactMap { if case .image(let image) = $0 { image } else { nil } }
            #expect(images.count == 1 && images.first?.contentTime == time)
            #expect(prepared.plan.time.frame == index)
        }
    }

    /// 完整真实LayerAttributesV2的已核对payload；所在层还含未支持mask，片段通过不表示整层可播。
    private func realPayload() throws -> Data {
        try PAGFixtures.data(named: "list/2.pag").subdata(in: 2154..<2195)
    }

    /// 使用实际属性读取入口验证字段边界，失败保持其原错误，不跳过同文件的其他语义门禁。
    private func decode(_ data: Data, budget: Int = 1_000_000, version: UInt16 = 52) throws -> LayerAttributes {
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: budget))
        var reader = PAGByteReader(data: data)
        let layer = try decoder.readLayerAttributes(code: version, reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        return layer
    }

    /// 只读取有源码证据的独立属性字段；不包成自称有效的完整PAG。
    private func fragment(_ attributes: [UInt8], version: UInt16 = 52) throws -> LayerAttributes {
        try decode(Data(attributes), version: version)
    }

    /// 在直接语义图中挂入时间元数据，不凭空编码整份PAG。
    private func timedLayer(_ id: UInt32, content: SourceLayerContent, timing: SourceLayerTiming) -> SourceLayer {
        SourceLayer(id: id, name: "timed", parentID: nil, startFrame: 0, durationFrames: 30, isActive: true,
                    transform: SourceTransformProperties(constant: SceneFixtures.transform), content: content, timing: timing)
    }
}
