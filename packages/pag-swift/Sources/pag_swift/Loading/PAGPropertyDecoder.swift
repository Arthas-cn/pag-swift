/// 关键帧共有的编码头；数组数量一致，时间数组比插值类型多一项。
struct KeyframeHeader {
    /// AttributeHelper::ReadKeyframes 的两位类型：0/1 线性、2 Bezier、3 Hold。
    let kinds: [UInt32]
    /// 连续且不倒序的端点，允许真实文件中的零跨度，差值必须可表示。
    let times: [Int64]
    /// 当前属性的关键帧段数，大于零。
    var count: Int { kinds.count }
}

/// 标量、颜色、二维、路径及opacity轨道读取；共用完整时间/缓动布局，不把动画当常量消费。
extension PAGSceneDecoder {
    /// Color的每个值是RGB三字节；SimpleProperty的三个通道共用一套缓动，不读取三份ease。
    mutating func readColorProperty(_ flag: PropertyFlags, defaultValue: SceneColor,
                                    reader: inout PAGByteReader) throws -> SourceProperty<SceneColor> {
        try Task.checkCancellation()
        guard flag.exists else { return SourceProperty(constant: defaultValue) }
        guard flag.isAnimated else { return SourceProperty(constant: try StaticAttributes.color(from: &reader)) }
        let header = try readKeyframeHeader(reader: &reader)
        var values: [SceneColor] = []
        for _ in 0...header.count {
            try Task.checkCancellation()
            values.append(try StaticAttributes.color(from: &reader))
        }
        let easings = try readEasings(header: header, dimensions: 1, reader: &reader)
        return try makeProperty(header: header, values: values, easings: easings)
    }

    /// PathHandle每个值独立ReadPath，最后一个路径的剩余位紧接时间缓动；非Hold段验证可插值拓扑。
    mutating func readPathProperty(_ flag: PropertyFlags, reader: inout PAGByteReader) throws -> SourceProperty<SourcePath> {
        try Task.checkCancellation()
        guard flag.exists else {
            try budget.reserve(128)
            return try SourceProperty(constant: SourcePath(verbs: [], points: []))
        }
        guard flag.isAnimated else { return try SourceProperty(constant: readPath(reader: &reader)) }
        let header = try readKeyframeHeader(reader: &reader)
        var values: [SourcePath] = []
        for _ in 0...header.count {
            try Task.checkCancellation()
            values.append(try readPath(reader: &reader))
        }
        let easings = try readEasings(header: header, dimensions: 1, reader: &reader)
        for index in 0..<header.count where header.kinds[index] != 3 {
            try values[index].validateInterpolation(to: values[index + 1])
        }
        return try makeProperty(header: header, values: values, easings: easings)
    }

    /// Frame属性按Attributes<Frame>逐个ReadTime，保留Int64原值；不把列表读成Float32或压缩Int32。
    mutating func readFrameProperty(_ flag: PropertyFlags, reader: inout PAGByteReader) throws -> SourceProperty<Int64> {
        guard flag.exists else { return SourceProperty(constant: 0) }
        guard flag.isAnimated else { return SourceProperty(constant: try StaticAttributes.frame(from: &reader)) }
        let header = try readKeyframeHeader(reader: &reader)
        var values: [Int64] = []
        for _ in 0...header.count {
            try Task.checkCancellation()
            values.append(try StaticAttributes.frame(from: &reader))
        }
        let easings = try readEasings(header: header, dimensions: 1, reader: &reader)
        return try makeProperty(header: header, values: values, easings: easings)
    }

    /// Float32 常量/列表按 Attributes<float> 读取，静态与动画都校验有限性。
    mutating func readScalarProperty(_ flag: PropertyFlags, defaultValue: Double,
                                     reader: inout PAGByteReader) throws -> SourceProperty<Double> {
        guard flag.exists else { return SourceProperty(constant: defaultValue) }
        guard flag.isAnimated else { return SourceProperty(constant: try StaticAttributes.scalar(from: &reader)) }
        let header = try readKeyframeHeader(reader: &reader)
        var values: [Double] = []
        for _ in 0...header.count {
            try Task.checkCancellation()
            values.append(try StaticAttributes.scalar(from: &reader))
        }
        let easings = try readEasings(header: header, dimensions: 1, reader: &reader)
        return try makeProperty(header: header, values: values, easings: easings)
    }

    /// Point 静态值是两个 Float32；Spatial 动画列表使用有符号位流与 0.05 Float 精度。
    mutating func readPointProperty(_ flag: PropertyFlags, defaultValue: ScenePoint, spatial: Bool,
                                    reader: inout PAGByteReader) throws -> SourceProperty<ScenePoint> {
        guard flag.exists else { return SourceProperty(constant: defaultValue) }
        guard flag.isAnimated else { return SourceProperty(constant: try StaticAttributes.point(from: &reader)) }
        let header = try readKeyframeHeader(reader: &reader)
        let width = try spatial ? reader.readBitWidth() : 0
        var values: [ScenePoint] = []
        for _ in 0...header.count {
            try Task.checkCancellation()
            if spatial { values.append(try packedPoint(width: width, precision: 0.05, reader: &reader)) }
            else { values.append(try StaticAttributes.point(from: &reader)) }
        }
        let easings = try readEasings(header: header, dimensions: spatial ? 1 : 2, reader: &reader)
        let paths = try flag.hasSpatial ? readSpatialCurves(header: header, values: values, reader: &reader) : []
        return try makeProperty(header: header, values: values, easings: easings, paths: paths)
    }

    /// UInt8 常量直接读取；动画值列表由 bit width 和连续无符号位值组成。
    mutating func readOpacityProperty(_ flag: PropertyFlags, reader: inout PAGByteReader) throws -> SourceProperty<UInt8> {
        guard flag.exists else { return SourceProperty(constant: 255) }
        guard flag.isAnimated else { return SourceProperty(constant: try reader.readUInt8()) }
        let header = try readKeyframeHeader(reader: &reader)
        let width = try reader.readBitWidth()
        var values: [UInt8] = []
        for _ in 0...header.count {
            try Task.checkCancellation()
            let value = try reader.readUnsignedBits(count: width)
            guard let byte = UInt8(exactly: value) else { throw SceneValidator.invalid("invalidOpacityValue") }
            values.append(byte)
        }
        let easings = try readEasings(header: header, dimensions: 1, reader: &reader)
        return try makeProperty(header: header, values: values, easings: easings)
    }

    /// 先按上游段数门禁和字节/预算限制，再读两位插值类型与 n+1 个连续 Frame。
    mutating func readKeyframeHeader(reader: inout PAGByteReader) throws -> KeyframeHeader {
        let count = Int(try reader.readEncodedUInt32())
        guard count > 0 else { throw SceneValidator.invalid("emptyKeyframes") }
        guard count <= 5_184_000 else { throw PAGError.resourceLimitExceeded("maximumKeyframes") }
        // 每个 Frame 至少一个字节，尚有 n+1 个时间，不能用短载荷驱动巨大分配。
        guard count < reader.remainingByteCount else { throw PAGError.truncatedData(offset: reader.position) }
        try budget.reserve(count: count, stride: 256)
        var kinds: [UInt32] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            kinds.append(try reader.readUnsignedBits(count: 2))
        }
        var times = [try StaticAttributes.frame(from: &reader)]
        for index in 0..<count {
            try Task.checkCancellation()
            let end = try StaticAttributes.frame(from: &reader)
            let start = times[index]
            // 真实导出含单独或尾部零跨度；求值器在端点直接取值，不会进入除零插值。
            guard end >= start, !end.subtractingReportingOverflow(start).overflow else {
                throw SceneValidator.invalid("invalidKeyframeTimes")
            }
            times.append(end)
        }
        return KeyframeHeader(kinds: kinds, times: times)
    }

    /// 拼合已消费的完整列表；原始相邻区间共用同一个边界值。
    func makeProperty<Value: Sendable>(header: KeyframeHeader, values: [Value], easings: [SourceEasing],
                                               paths: [SampledCurve?] = []) throws -> SourceProperty<Value> {
        var frames: [SourceKeyframe<Value>] = []
        for index in 0..<header.count {
            try Task.checkCancellation()
            frames.append(SourceKeyframe(startFrame: header.times[index], endFrame: header.times[index + 1],
                                         startValue: values[index], endValue: values[index + 1], easing: easings[index],
                                         spatialCurve: paths.isEmpty ? nil : paths[index]))
        }
        return try SourceProperty(keyframes: frames)
    }
}
