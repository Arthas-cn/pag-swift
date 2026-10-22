/// tag85按上游十项统一属性顺序读取；样式是否可画由图层组合门禁判断。
extension PAGSceneDecoder {
    /// 完整消费渐变叠加的静态/动画源字段；损坏、截断或预算不足不发布半条样式。
    mutating func readGradientOverlay(reader: inout PAGByteReader) throws -> SourceGradientOverlay {
        try Task.checkCancellation()
        try budget.reserve(512)
        let flags = try PropertyFlags.read(Array(repeating: .property, count: 9) + [.spatialProperty],
            from: &reader)
        let blend = try readDiscreteByteProperty(flags[0], defaultValue: 0,
            maximum: 255, reader: &reader)
        let opacity = try readOpacityProperty(flags[1], reader: &reader)
        let colors = try readGradientProperty(flags[2], reader: &reader)
        let smoothness = try readScalarProperty(flags[3], defaultValue: 100, reader: &reader)
        let angle = try readScalarProperty(flags[4], defaultValue: 90, reader: &reader)
        let style = try readDiscreteByteProperty(flags[5], defaultValue: 0,
            maximum: 4, reader: &reader)
        let reverse = try readDiscreteBoolProperty(flags[6], defaultValue: false, reader: &reader)
        let align = try readDiscreteBoolProperty(flags[7], defaultValue: true, reader: &reader)
        let scale = try readScalarProperty(flags[8], defaultValue: 100, reader: &reader)
        let offset = try readPointProperty(flags[9], defaultValue: .zero,
            spatial: true, reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        return SourceGradientOverlay(blendMode: blend, opacity: opacity, colors: colors,
            smoothness: smoothness, angle: angle, style: style, reverse: reverse,
            alignWithLayer: align, scale: scale, offset: offset)
    }
}
