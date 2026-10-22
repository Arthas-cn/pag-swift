/// tag56图像平铺效果的完整属性读取；其它图层和未证实的效果引用仍由层入口拒绝。
extension PAGSceneDecoder {
    /// 按上游MotionTileEffectTag的十项flags与载荷顺序读取轨道，拒绝非空自定义mask列表。
    mutating func readMotionTile(reader: inout PAGByteReader) throws -> SourceMotionTile {
        try Task.checkCancellation()
        try budget.reserve(512)
        let flags = try PropertyFlags.read([.spatialProperty, .property, .property,
            .property, .property, .property, .property, .property, .property, .flag],
            from: &reader)
        let center = try readPointProperty(flags[0], defaultValue: ScenePoint(x: 640, y: 360),
                                           spatial: true, reader: &reader)
        let width = try readScalarProperty(flags[1], defaultValue: 100, reader: &reader)
        let height = try readScalarProperty(flags[2], defaultValue: 100, reader: &reader)
        let outputWidth = try readScalarProperty(flags[3], defaultValue: 100, reader: &reader)
        let outputHeight = try readScalarProperty(flags[4], defaultValue: 100, reader: &reader)
        let mirror = try readDiscreteBoolProperty(flags[5], defaultValue: false, reader: &reader)
        let phase = try readScalarProperty(flags[6], defaultValue: 0, reader: &reader)
        let horizontal = try readDiscreteBoolProperty(flags[7], defaultValue: false, reader: &reader)
        let opacity = try readOpacityProperty(flags[8], reader: &reader)
        let count = try flags[9].exists ? Int(reader.readEncodedUInt32()) : 0
        guard count <= reader.remainingByteCount else { throw PAGError.truncatedData(offset: reader.position) }
        try budget.reserve(count: count, stride: 32)
        for _ in 0..<count {
            try Task.checkCancellation()
            _ = try reader.readEncodedUInt32()
        }
        try StaticAttributes.requireEnd(of: reader)
        // 当前MotionTileFilter没有消费通用effectOpacity或maskReferences；非默认值不误报为已验收。
        guard !opacity.isAnimated, opacity.initialValue == 255 else {
            throw PAGError.unsupportedFeature("motionTileOpacity")
        }
        guard count == 0 else { throw PAGError.unsupportedFeature("motionTileEffectMasks") }
        return SourceMotionTile(center: center, tileWidth: width, tileHeight: height,
            outputWidth: outputWidth, outputHeight: outputHeight, mirrorEdges: mirror,
            phase: phase, horizontalPhaseShift: horizontal)
    }
}
