/// tag57仅接受真实Screen预合成已证实的绿通道直通子范围。
extension PAGSceneDecoder {
    /// 完整读取二十个颜色轨道及共同合成选项；其它取值明确失败，不忽略效果。
    mutating func readGreenOnlyLevels(reader: inout PAGByteReader) throws {
        try Task.checkCancellation()
        try budget.reserve(512)
        let flags = try PropertyFlags.read(Array(repeating: AttributeEncoding.property, count: 21) + [.flag],
            from: &reader)
        let defaults: [Double] = [0, 255, 1, 0, 255]
        for index in 0..<20 {
            try Task.checkCancellation()
            let value = try readScalarProperty(flags[index], defaultValue: defaults[index % 5], reader: &reader)
            let expected = index == 9 || index == 19 ? 0 : defaults[index % 5]
            guard !value.isAnimated, value.initialValue == expected else {
                throw PAGError.unsupportedFeature("levelsIndividualParameters")
            }
        }
        let opacity = try readOpacityProperty(flags[20], reader: &reader)
        let count = try flags[21].exists ? Int(reader.readEncodedUInt32()) : 0
        guard count <= reader.remainingByteCount else { throw PAGError.truncatedData(offset: reader.position) }
        try budget.reserve(count: count, stride: 32)
        for _ in 0..<count {
            try Task.checkCancellation()
            _ = try reader.readEncodedUInt32()
        }
        try StaticAttributes.requireEnd(of: reader)
        guard !opacity.isAnimated, opacity.initialValue == 255, count == 0 else {
            throw PAGError.unsupportedFeature("levelsIndividualCompositing")
        }
    }
}
