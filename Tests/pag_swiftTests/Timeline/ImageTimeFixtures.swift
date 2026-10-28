@testable import pag_swift

/// ImageFillRule独立语义图和真实属性块入口，不拼装自称合法的完整PAG。
enum ImageTimeFixtures {
    /// 读取AudioMarker层329的实际tag54载荷；传67只比较同布局的版本规则，不声称存在真实V2文件。
    static func realRule(version: UInt16 = 54) throws -> SourceImageFillRule {
        let payload = try PAGFixtures.data(named: "AudioMarker.pag").subdata(in: 1_971_301..<1_971_319)
        var reader = PAGByteReader(data: payload)
        var decoder = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 1_000_000))
        return try decoder.readImageFillRule(code: version, reader: &reader)
    }

    /// 创建有图片内容的语义层，可指定规则或缺失规则；不绕过完整文件的其他语义门禁。
    static func layer(id: UInt32 = 1, start: Int64 = 0, duration: Int64 = 11,
                      rule: SourceImageFillRule? = nil) -> SourceLayer {
        SourceLayer(id: id, name: "image", parentID: nil, startFrame: start, durationFrames: duration,
                    isActive: true, transform: SourceTransformProperties(constant: SceneFixtures.transform),
                    content: .image(1), imageFillRule: rule)
    }

    /// 直接语义关键帧，后续SourceProperty负责拓扑校验；不是PAG字节记录。
    static func key(_ start: Int64, _ end: Int64, _ a: Int64, _ b: Int64,
                    _ easing: SourceEasing = .linear) -> SourceKeyframe<Int64> {
        SourceKeyframe(startFrame: start, endFrame: end, startValue: a, endValue: b, easing: easing, spatialCurve: nil)
    }

    /// 从有证据的帧值轨道建立测试规则，缩放方式可与文件级表冲突以验证优先级。
    static func rule(_ keys: [SourceKeyframe<Int64>], mode: PAGScaleMode = .aspectFit) throws -> SourceImageFillRule {
        SourceImageFillRule(scaleMode: mode, timeRemap: try SourceProperty(keyframes: keys))
    }

    /// 为独立映射测试提供受限准备预算，返回实际生产映射而不是另一套测试时钟。
    static func mapping(_ layer: SourceLayer, visible: ClosedRange<Int64>, fileDuration: Int64 = 30,
                        maximumBytes: Int = 1_000_000) throws -> ImageTimeMapping {
        var budget = FramePlanBudget(limit: maximumBytes, resourceName: "maximumPreparedSceneBytes")
        return try ImageTimeMapping.make(layer: layer, visibleStart: visible.lowerBound,
                                         visibleEnd: visible.upperBound, fileDuration: fileDuration, budget: &budget)
    }

    /// 同一源图片由不同偏移预合成引用；PNG输入与PAG语义图分开，文件级stretch用于验证规则优先级。
    static func file(rule: SourceImageFillRule?, start: Int64 = 2, duration: Int64 = 11,
                     offsets: [Int64] = [0, 4], childRate: Double = 30, rootRate: Double = 30,
                     fileDuration: Int64 = 30, childDuration: Int64? = nil) async throws -> PAGFile {
        let input = try await PAGImage.load(data: PAGFixtures.data(named: "media/rgba-corners.png"))
        let size = try PAGSize(width: 100, height: 80)
        let image = SourceImage(id: 1, image: input, logicalSize: size, scaleFactor: 1, anchor: .zero)
        let child = SourceComposition(id: 1, size: size, durationFrames: childDuration ?? fileDuration, frameRate: childRate,
            background: .defaultFill, layers: [layer(id: 11, start: start, duration: duration, rule: rule)])
        let layers = offsets.enumerated().map { index, offset in
            SceneFixtures.layer(UInt32(index + 21), duration: fileDuration, content: .precomposition(id: 1, startFrame: offset))
        }
        let root = SourceComposition(id: 2, size: size, durationFrames: fileDuration, frameRate: rootRate,
                                     background: .defaultFill, layers: layers)
        return try SceneFixtures.build([child, root], resources: SourceResources(images: [1: image], imageScaleModes: [.stretch]))
    }
}
