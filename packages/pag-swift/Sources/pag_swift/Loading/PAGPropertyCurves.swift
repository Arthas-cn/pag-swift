/// 时间与空间曲线的证据化读取和预计算；播放只持有构造完成的不可变折线。
extension PAGSceneDecoder {
    /// ReadTimeEase 即使没有 Bezier 也读 bit width；二维 MultiDimension 每段有两套控制点。
    mutating func readEasings(header: KeyframeHeader, dimensions: Int,
                              reader: inout PAGByteReader) throws -> [SourceEasing] {
        let width = try reader.readBitWidth()
        var result: [SourceEasing] = []
        for kind in header.kinds {
            try Task.checkCancellation()
            switch kind {
            case 3: result.append(.hold)
            case 2:
                let first = try readTimingCurve(width: width, reader: &reader)
                let second = try dimensions == 2 ? readTimingCurve(width: width, reader: &reader) : nil
                result.append(.bezier(first: first, second: second))
            default:
                // 当前标量/Point 配置在 None=0 时也创建普通插值器；与 Linear=1 求值相同。
                result.append(.linear)
            }
        }
        return result
    }

    /// ReadSpatialEase 先读全部 in/out 存在位，再读共同位宽和每段切线。
    mutating func readSpatialCurves(header: KeyframeHeader, values: [ScenePoint],
                                    reader: inout PAGByteReader) throws -> [SampledCurve?] {
        var flags: [(input: Bool, output: Bool)] = []
        for _ in 0..<header.count {
            try Task.checkCancellation()
            flags.append((try reader.readUnsignedBits(count: 1) != 0, try reader.readUnsignedBits(count: 1) != 0))
        }
        let width = try reader.readBitWidth()
        var paths: [SampledCurve?] = []
        for index in 0..<header.count {
            try Task.checkCancellation()
            let input = try flags[index].input ? packedPoint(width: width, precision: 0.05, reader: &reader) : .zero
            let output = try flags[index].output ? packedPoint(width: width, precision: 0.05, reader: &reader) : .zero
            if header.kinds[index] == 3 {
                // Hold 同样消费切线编码，但上游选择的基类只返回起点值，不生成空间曲线。
                paths.append(nil)
                continue
            }
            let start = values[index]
            let end = values[index + 1]
            let first = ScenePoint(x: Double(Float(start.x) + Float(output.x)), y: Double(Float(start.y) + Float(output.y)))
            let second = ScenePoint(x: Double(Float(end.x) + Float(input.x)), y: Double(Float(end.y) + Float(input.y)))
            paths.append(try SampledCurve.make(start: start, control1: first, control2: second, end: end,
                                               precision: 0.05, budget: &budget))
        }
        return paths
    }

    /// 有符号位坐标先按上游 Float 精度相乘，再扩为场景 Double；不改成十进制精确运算。
    func packedPoint(width: Int, precision: Float, reader: inout PAGByteReader) throws -> ScenePoint {
        let x = Float(try reader.readSignedBits(count: width)) * precision
        let y = Float(try reader.readSignedBits(count: width)) * precision
        return ScenePoint(x: Double(x), y: Double(y))
    }

    /// 四个有符号分量以 0.005 精度编码 out/in 控制点；x 必须可作单调时间查询。
    private mutating func readTimingCurve(width: Int, reader: inout PAGByteReader) throws -> SampledCurve {
        let first = try packedPoint(width: width, precision: 0.005, reader: &reader)
        let second = try packedPoint(width: width, precision: 0.005, reader: &reader)
        guard (0...1).contains(first.x), (0...1).contains(second.x) else {
            throw SceneValidator.invalid("invalidTimingControlPoint")
        }
        return try SampledCurve.make(start: .zero, control1: first, control2: second, end: .one,
                                     precision: 0.005, budget: &budget)
    }
}
