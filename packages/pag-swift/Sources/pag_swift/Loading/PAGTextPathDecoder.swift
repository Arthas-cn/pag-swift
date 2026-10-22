/// TextPathOptionTag的独立字段读取；正式层入口已在路径字形画面闭环后接通。
extension PAGSceneDecoder {
    /// 按上游tag69六字段顺序完整消费载荷；缺失引用保留0，损坏或预算不足立即失败。
    mutating func readTextPathOption(reader: inout PAGByteReader) throws -> SourceTextPathOption {
        try Task.checkCancellation()
        try budget.reserve(256)
        let flags = try PropertyFlags.read([.flag, .property, .property, .property, .property, .property],
                                           from: &reader)
        let maskID = try flags[0].exists ? reader.readEncodedUInt32() : 0
        let reversed = try readDiscreteBoolProperty(flags[1], defaultValue: false, reader: &reader)
        let perpendicular = try readDiscreteBoolProperty(flags[2], defaultValue: true, reader: &reader)
        let forceAlignment = try readDiscreteBoolProperty(flags[3], defaultValue: false, reader: &reader)
        let firstMargin = try readScalarProperty(flags[4], defaultValue: 0, reader: &reader)
        let lastMargin = try readScalarProperty(flags[5], defaultValue: 0, reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        return SourceTextPathOption(maskID: maskID, reversed: reversed, perpendicular: perpendicular,
                                    forceAlignment: forceAlignment, firstMargin: firstMargin, lastMargin: lastMargin)
    }

    /// DiscreteProperty<bool>动画没有插值位，时间后紧接n+1个逐位布尔值；段内保持起点值。
    mutating func readDiscreteBoolProperty(_ flag: PropertyFlags, defaultValue: Bool,
                                           reader: inout PAGByteReader) throws -> SourceProperty<Bool> {
        guard flag.exists else { return SourceProperty(constant: defaultValue) }
        guard flag.isAnimated else { return SourceProperty(constant: try reader.readUInt8() != 0) }
        let count = Int(try reader.readEncodedUInt32())
        guard count > 0 else { throw SceneValidator.invalid("emptyKeyframes") }
        guard count <= 5_184_000 else { throw PAGError.resourceLimitExceeded("maximumKeyframes") }
        guard count < reader.remainingByteCount else { throw PAGError.truncatedData(offset: reader.position) }
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
        var values: [Bool] = []
        for _ in 0...count {
            try Task.checkCancellation()
            values.append(try reader.readUnsignedBits(count: 1) != 0)
        }
        var frames: [SourceKeyframe<Bool>] = []
        for index in 0..<count {
            try Task.checkCancellation()
            frames.append(SourceKeyframe(startFrame: times[index], endFrame: times[index + 1],
                startValue: values[index], endValue: values[index + 1], easing: .hold, spatialCurve: nil))
        }
        return try SourceProperty(keyframes: frames)
    }
}
