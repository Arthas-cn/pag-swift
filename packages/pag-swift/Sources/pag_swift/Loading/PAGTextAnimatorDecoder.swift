/// tag70及其子标签的有界内部读取；正式Layer入口仍由完整绘制能力控制。
extension PAGSceneDecoder {
    /// 按TextAnimatorTag.cpp逐个读取子标签；未知字段不能被误报为已支持动画。
    mutating func readTextAnimator(reader: inout PAGByteReader) throws -> SourceTextAnimator {
        try Task.checkCancellation()
        try budget.reserve(256)
        var selectors: [SourceTextSelector] = []
        var trackingType: SourceProperty<UInt8>?
        var trackingAmount: SourceProperty<Double>?
        var fillColor: SourceProperty<SceneColor>?
        var strokeColor: SourceProperty<SceneColor>?
        var position: SourceProperty<ScenePoint>?
        var scale: SourceProperty<ScenePoint>?
        var rotation: SourceProperty<Double>?
        var opacity: SourceProperty<UInt8>?
        while var block = try nextBlock(from: &reader) {
            try Task.checkCancellation()
            switch block.code {
            case 71:
                try budget.reserve(256)
                selectors.append(.range(try readTextRangeSelector(reader: &block.reader)))
            case 80:
                try budget.reserve(256)
                selectors.append(.wiggly(try readTextWigglySelector(reader: &block.reader)))
            case 72:
                guard trackingType == nil else { throw SceneValidator.invalid("duplicateTextAnimatorProperty") }
                let flags = try PropertyFlags.read([.property], from: &block.reader)
                trackingType = try readDiscreteByteProperty(flags[0], defaultValue: 0, maximum: 2, reader: &block.reader)
            case 73:
                guard trackingAmount == nil else { throw SceneValidator.invalid("duplicateTextAnimatorProperty") }
                let flags = try PropertyFlags.read([.property], from: &block.reader)
                trackingAmount = try readScalarProperty(flags[0], defaultValue: 0, reader: &block.reader)
            case 74:
                guard fillColor == nil else { throw SceneValidator.invalid("duplicateTextAnimatorProperty") }
                let flags = try PropertyFlags.read([.property], from: &block.reader)
                fillColor = try readColorProperty(flags[0], defaultValue: .defaultFill, reader: &block.reader)
            case 75:
                guard strokeColor == nil else { throw SceneValidator.invalid("duplicateTextAnimatorProperty") }
                let flags = try PropertyFlags.read([.property], from: &block.reader)
                strokeColor = try readColorProperty(flags[0], defaultValue: .defaultFill, reader: &block.reader)
            case 76:
                guard position == nil else { throw SceneValidator.invalid("duplicateTextAnimatorProperty") }
                let flags = try PropertyFlags.read([.spatialProperty], from: &block.reader)
                position = try readPointProperty(flags[0], defaultValue: .zero, spatial: true, reader: &block.reader)
            case 77:
                guard scale == nil else { throw SceneValidator.invalid("duplicateTextAnimatorProperty") }
                let flags = try PropertyFlags.read([.property], from: &block.reader)
                scale = try readPointProperty(flags[0], defaultValue: .one, spatial: false, reader: &block.reader)
            case 78:
                guard rotation == nil else { throw SceneValidator.invalid("duplicateTextAnimatorProperty") }
                let flags = try PropertyFlags.read([.property], from: &block.reader)
                rotation = try readScalarProperty(flags[0], defaultValue: 0, reader: &block.reader)
            case 79:
                guard opacity == nil else { throw SceneValidator.invalid("duplicateTextAnimatorProperty") }
                let flags = try PropertyFlags.read([.property], from: &block.reader)
                opacity = try readOpacityProperty(flags[0], reader: &block.reader)
            default:
                // 当前子集不忽略未知子标签；否则成功文件可能丢掉未来版本的画面语义。
                throw PAGError.unsupportedFeature("textAnimatorTag:\(block.code)")
            }
            try StaticAttributes.requireEnd(of: block.reader)
        }
        return SourceTextAnimator(selectors: selectors, trackingType: trackingType,
            trackingAmount: trackingAmount, fillColor: fillColor, strokeColor: strokeColor,
            position: position, scale: scale, rotation: rotation, opacity: opacity)
    }

    /// 按TextSelector.cpp中13项flags和载荷顺序读取Range；保留上游暂未消费的字段。
    mutating func readTextRangeSelector(reader: inout PAGByteReader) throws -> SourceTextRangeSelector {
        try Task.checkCancellation()
        let flags = try PropertyFlags.read([.property, .property, .property, .flag, .flag,
            .property, .property, .flag, .property, .property, .property, .flag, .property], from: &reader)
        let start = try readScalarProperty(flags[0], defaultValue: 0, reader: &reader)
        let end = try readScalarProperty(flags[1], defaultValue: 1, reader: &reader)
        let offset = try readScalarProperty(flags[2], defaultValue: 0, reader: &reader)
        let units = try readTextEnum(flags[3], defaultValue: 0, maximum: 1, reader: &reader)
        let basedOn = try readTextEnum(flags[4], defaultValue: 0, maximum: 3, reader: &reader)
        let mode = try readDiscreteByteProperty(flags[5], defaultValue: 1, maximum: 6, reader: &reader)
        let amount = try readScalarProperty(flags[6], defaultValue: 1, reader: &reader)
        let shape = try readTextEnum(flags[7], defaultValue: 0, maximum: 5, reader: &reader)
        let smoothness = try readScalarProperty(flags[8], defaultValue: 1, reader: &reader)
        let easeHigh = try readScalarProperty(flags[9], defaultValue: 0, reader: &reader)
        let easeLow = try readScalarProperty(flags[10], defaultValue: 0, reader: &reader)
        let seed = try readTextSeedProperty(flags[12], reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        return SourceTextRangeSelector(start: start, end: end, offset: offset, units: units,
            basedOn: basedOn, mode: mode, amount: amount, shape: shape, smoothness: smoothness,
            easeHigh: easeHigh, easeLow: easeLow, randomizeOrder: flags[11].exists, randomSeed: seed)
    }

    /// 按TextSelector.cpp中10项flags和载荷顺序读取Wiggly；布尔轨道不消费插值位。
    mutating func readTextWigglySelector(reader: inout PAGByteReader) throws -> SourceTextWigglySelector {
        try Task.checkCancellation()
        let flags = try PropertyFlags.read([.property, .property, .property, .flag, .property,
            .property, .property, .property, .property, .property], from: &reader)
        let mode = try readDiscreteByteProperty(flags[0], defaultValue: 3, maximum: 6, reader: &reader)
        let maxAmount = try readScalarProperty(flags[1], defaultValue: 1, reader: &reader)
        let minAmount = try readScalarProperty(flags[2], defaultValue: -1, reader: &reader)
        let basedOn = try readTextEnum(flags[3], defaultValue: 0, maximum: 3, reader: &reader)
        let wiggles = try readScalarProperty(flags[4], defaultValue: 2, reader: &reader)
        let correlation = try readScalarProperty(flags[5], defaultValue: 0.5, reader: &reader)
        let temporal = try readScalarProperty(flags[6], defaultValue: 0, reader: &reader)
        let spatial = try readScalarProperty(flags[7], defaultValue: 0, reader: &reader)
        let lock = try readDiscreteBoolProperty(flags[8], defaultValue: false, reader: &reader)
        let seed = try readTextSeedProperty(flags[9], reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        return SourceTextWigglySelector(mode: mode, maxAmount: maxAmount, minAmount: minAmount,
            basedOn: basedOn, wigglesPerSecond: wiggles, correlation: correlation,
            temporalPhase: temporal, spatialPhase: spatial, lockDimensions: lock, randomSeed: seed)
    }

    /// 读取Text Value枚举的单字节值；缺省值来自tag配置而不是文件推断。
    private func readTextEnum(_ flag: PropertyFlags, defaultValue: UInt8, maximum: UInt8,
                              reader: inout PAGByteReader) throws -> UInt8 {
        let value = try flag.exists ? reader.readUInt8() : defaultValue
        guard value <= maximum else { throw SceneValidator.invalid("unknownTextAnimatorEnum") }
        return value
    }

    /// DiscreteProperty<UInt8>无插值位，动画列表仍采用共同UInt32位宽编码。
    mutating func readDiscreteByteProperty(_ flag: PropertyFlags, defaultValue: UInt8,
                                           maximum: UInt8, reader: inout PAGByteReader) throws -> SourceProperty<UInt8> {
        guard flag.exists else { return SourceProperty(constant: defaultValue) }
        if !flag.isAnimated {
            let value = try reader.readUInt8()
            guard value <= maximum else { throw SceneValidator.invalid("unknownTextAnimatorEnum") }
            return SourceProperty(constant: value)
        }
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
        let width = try reader.readBitWidth()
        var values: [UInt8] = []
        for _ in 0...count {
            try Task.checkCancellation()
            let value = try reader.readUnsignedBits(count: width)
            guard value <= maximum else { throw SceneValidator.invalid("unknownTextAnimatorEnum") }
            values.append(UInt8(value))
        }
        var frames: [SourceKeyframe<UInt8>] = []
        for index in 0..<count {
            try Task.checkCancellation()
            frames.append(SourceKeyframe(startFrame: times[index], endFrame: times[index + 1],
                startValue: values[index], endValue: values[index + 1], easing: .hold, spatialCurve: nil))
        }
        return try SourceProperty(keyframes: frames)
    }

    /// UInt16种子常量是EncodedUInt32，动画列表是位宽打包；拒绝不能表示的源值。
    mutating func readTextSeedProperty(_ flag: PropertyFlags,
                                       reader: inout PAGByteReader) throws -> SourceProperty<UInt16> {
        guard flag.exists else { return SourceProperty(constant: 0) }
        if !flag.isAnimated {
            let value = try reader.readEncodedUInt32()
            guard let seed = UInt16(exactly: value) else { throw SceneValidator.invalid("invalidTextAnimatorSeed") }
            return SourceProperty(constant: seed)
        }
        let header = try readKeyframeHeader(reader: &reader)
        let width = try reader.readBitWidth()
        var values: [UInt16] = []
        for _ in 0...header.count {
            try Task.checkCancellation()
            let value = try reader.readUnsignedBits(count: width)
            guard let seed = UInt16(exactly: value) else { throw SceneValidator.invalid("invalidTextAnimatorSeed") }
            values.append(seed)
        }
        let easings = try readEasings(header: header, dimensions: 1, reader: &reader)
        return try makeProperty(header: header, values: values, easings: easings)
    }
}
