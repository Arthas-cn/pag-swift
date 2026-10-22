/// FastBlurEffectTag字段读取；图层入口按已验证的预合成和Shape效果组合分别守门。
extension PAGSceneDecoder {
    /// 完整消费blurriness、方向、重复边缘和共同合成选项。
    mutating func readFastBlur(reader: inout PAGByteReader) throws -> SourceFastBlur {
        try Task.checkCancellation()
        try budget.reserve(256)
        let flags = try PropertyFlags.read([.property, .property, .property, .property, .flag],
                                           from: &reader)
        let blurriness = try readScalarProperty(flags[0], defaultValue: 0, reader: &reader)
        let direction = try readFastBlurDirection(flags[1], reader: &reader)
        let repeatEdge = try readDiscreteBoolProperty(flags[2], defaultValue: false, reader: &reader)
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
        // 尚无通用效果opacity和mask的GPU合成，非默认值不能当成无条件Blur。
        guard !opacity.isAnimated, opacity.initialValue == 255 else {
            throw PAGError.unsupportedFeature("fastBlurOpacity")
        }
        guard count == 0 else { throw PAGError.unsupportedFeature("fastBlurEffectMasks") }
        return SourceFastBlur(blurriness: blurriness, direction: direction,
                              repeatEdgePixels: repeatEdge)
    }

    /// 离散方向只接受上游0/1/2；动画段始终保持起点，不插值为未知枚举。
    private mutating func readFastBlurDirection(_ flag: PropertyFlags,
                                                reader: inout PAGByteReader) throws -> SourceProperty<UInt8> {
        guard flag.exists else { return SourceProperty(constant: 0) }
        if !flag.isAnimated {
            let value = try reader.readUInt8()
            guard value <= 2 else { throw SceneValidator.invalid("unknownFastBlurDirection") }
            return SourceProperty(constant: value)
        }
        let count = Int(try reader.readEncodedUInt32())
        guard count > 0 else { throw SceneValidator.invalid("emptyKeyframes") }
        guard count <= 5_184_000 else { throw PAGError.resourceLimitExceeded("maximumKeyframes") }
        guard count < reader.remainingByteCount else {
            throw PAGError.truncatedData(offset: reader.position)
        }
        try budget.reserve(count: count, stride: 256)
        var times = [try StaticAttributes.frame(from: &reader)]
        for _ in 0..<count {
            try Task.checkCancellation()
            let end = try StaticAttributes.frame(from: &reader)
            guard end >= times[times.count - 1],
                  !end.subtractingReportingOverflow(times[times.count - 1]).overflow else {
                throw SceneValidator.invalid("invalidKeyframeTimes")
            }
            times.append(end)
        }
        let width = try reader.readBitWidth()
        var values: [UInt8] = []
        for _ in 0...count {
            try Task.checkCancellation()
            let value = try reader.readUnsignedBits(count: width)
            guard value <= 2 else { throw SceneValidator.invalid("unknownFastBlurDirection") }
            values.append(UInt8(value))
        }
        var frames: [SourceKeyframe<UInt8>] = []
        for index in 0..<count {
            try Task.checkCancellation()
            frames.append(SourceKeyframe(startFrame: times[index], endFrame: times[index + 1],
                startValue: values[index], endValue: values[index + 1],
                easing: .hold, spatialCurve: nil))
        }
        return try SourceProperty(keyframes: frames)
    }
}
