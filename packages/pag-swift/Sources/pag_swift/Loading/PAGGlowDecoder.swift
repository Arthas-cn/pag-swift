/// tag61按GlowEffectTag的三条SimpleProperty与共同合成选项读取。
extension PAGSceneDecoder {
    /// 完整消费Glow字段；非默认效果opacity或自定义mask仍保持明确门禁。
    mutating func readGlow(reader: inout PAGByteReader) throws -> SourceGlow {
        try Task.checkCancellation()
        try budget.reserve(256)
        let flags = try PropertyFlags.read([.property, .property, .property, .property, .flag],
                                           from: &reader)
        let threshold = try readScalarProperty(flags[0], defaultValue: 1, reader: &reader)
        let radius = try readScalarProperty(flags[1], defaultValue: 100, reader: &reader)
        let intensity = try readScalarProperty(flags[2], defaultValue: 0, reader: &reader)
        let opacity = try readOpacityProperty(flags[3], reader: &reader)
        let count = try flags[4].exists ? Int(reader.readEncodedUInt32()) : 0
        guard count <= reader.remainingByteCount else {
            throw PAGError.truncatedData(offset: reader.position)
        }
        try budget.reserve(count: count, stride: 32)
        for _ in 0..<count {
            try Task.checkCancellation()
            _ = try reader.readEncodedUInt32()
        }
        try StaticAttributes.requireEnd(of: reader)
        // 共同合成选项尚无GPU消费路径；接受它们会把非默认画面错误当成已实现。
        guard !opacity.isAnimated, opacity.initialValue == 255 else {
            throw PAGError.unsupportedFeature("glowOpacity")
        }
        guard count == 0 else { throw PAGError.unsupportedFeature("glowEffectMasks") }
        return SourceGlow(threshold: threshold, radius: radius, intensity: intensity)
    }
}
