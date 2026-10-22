/// tag58读取遵从上游CornerPinEffectTag的四角Spatial字段及统一效果合成选项。
extension PAGSceneDecoder {
    /// 消费全部四角、opacity和mask引用；未验收的效果合成选项明确拒绝。
    mutating func readCornerPin(reader: inout PAGByteReader) throws -> SourceCornerPin {
        try Task.checkCancellation()
        try budget.reserve(512)
        let flags = try PropertyFlags.read([.spatialProperty, .spatialProperty,
            .spatialProperty, .spatialProperty, .property, .flag], from: &reader)
        let upperLeft = try readPointProperty(flags[0], defaultValue: .zero,
            spatial: true, reader: &reader)
        let upperRight = try readPointProperty(flags[1], defaultValue: ScenePoint(x: 1280, y: 0),
            spatial: true, reader: &reader)
        let lowerLeft = try readPointProperty(flags[2], defaultValue: ScenePoint(x: 0, y: 720),
            spatial: true, reader: &reader)
        let lowerRight = try readPointProperty(flags[3], defaultValue: ScenePoint(x: 1280, y: 720),
            spatial: true, reader: &reader)
        let opacity = try readOpacityProperty(flags[4], reader: &reader)
        let count = try flags[5].exists ? Int(reader.readEncodedUInt32()) : 0
        guard count <= reader.remainingByteCount else { throw PAGError.truncatedData(offset: reader.position) }
        try budget.reserve(count: count, stride: 32)
        for _ in 0..<count {
            try Task.checkCancellation()
            _ = try reader.readEncodedUInt32()
        }
        try StaticAttributes.requireEnd(of: reader)
        // 通用效果选项若非默认，直采片元不能替代局部内容与mask先合成的语义。
        guard !opacity.isAnimated, opacity.initialValue == 255 else {
            throw PAGError.unsupportedFeature("cornerPinOpacity")
        }
        guard count == 0 else { throw PAGError.unsupportedFeature("cornerPinEffectMasks") }
        return SourceCornerPin(upperLeft: upperLeft, upperRight: upperRight,
            lowerLeft: lowerLeft, lowerRight: lowerRight)
    }
}
