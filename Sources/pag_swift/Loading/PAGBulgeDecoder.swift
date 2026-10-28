/// tag59的八项源字段读取；画面接线只允许独立图像层子范围。
extension PAGSceneDecoder {
    /// 完整消费半径、中心、高度、taper、pinning、opacity和mask列表，拒绝未实现合成选项。
    mutating func readBulge(reader: inout PAGByteReader) throws -> SourceBulge {
        try Task.checkCancellation()
        try budget.reserve(512)
        let flags = try PropertyFlags.read([.property, .property, .spatialProperty,
            .property, .property, .property, .property, .flag], from: &reader)
        let horizontal = try readScalarProperty(flags[0], defaultValue: 50, reader: &reader)
        let vertical = try readScalarProperty(flags[1], defaultValue: 50, reader: &reader)
        let center = try readPointProperty(flags[2], defaultValue: ScenePoint(x: 640, y: 360),
            spatial: true, reader: &reader)
        let height = try readScalarProperty(flags[3], defaultValue: 1, reader: &reader)
        let taper = try readScalarProperty(flags[4], defaultValue: 0, reader: &reader)
        let pinning = try readDiscreteBoolProperty(flags[5], defaultValue: false, reader: &reader)
        let opacity = try readOpacityProperty(flags[6], reader: &reader)
        let count = try flags[7].exists ? Int(reader.readEncodedUInt32()) : 0
        guard count <= reader.remainingByteCount else { throw PAGError.truncatedData(offset: reader.position) }
        try budget.reserve(count: count, stride: 32)
        for _ in 0..<count {
            try Task.checkCancellation()
            _ = try reader.readEncodedUInt32()
        }
        try StaticAttributes.requireEnd(of: reader)
        // 通用效果透明度及自定义mask若非默认，不能以无额外合成的直采路径伪装。
        guard !opacity.isAnimated, opacity.initialValue == 255 else {
            throw PAGError.unsupportedFeature("bulgeOpacity")
        }
        guard count == 0 else { throw PAGError.unsupportedFeature("bulgeEffectMasks") }
        return SourceBulge(horizontalRadius: horizontal, verticalRadius: vertical,
            center: center, height: height, taperRadius: taper, pinning: pinning)
    }
}
