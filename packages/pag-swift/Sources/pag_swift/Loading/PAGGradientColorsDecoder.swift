/// DataTypes::ReadGradientColor与Attributes<GradientColorHandle>的完整双表读取，不在这里生成色带。
extension PAGSceneDecoder {
    /// 每个关键值独立读两张表，再读一套时间ease；数量不同不影响源前缀插值的合法性。
    mutating func readGradientProperty(_ flag: PropertyFlags,
                                       reader: inout PAGByteReader) throws -> SourceProperty<SourceGradientColors> {
        try Task.checkCancellation()
        // 源缺省是两张空表，实际绘制会访问back；本库明确拒绝，不猜默认透明度或颜色。
        guard flag.exists else { throw PAGError.invalidFile(reason: "emptyGradientStops", offset: reader.position) }
        guard flag.isAnimated else { return try SourceProperty(constant: readGradientColors(reader: &reader)) }
        let header = try readKeyframeHeader(reader: &reader)
        var values: [SourceGradientColors] = []
        for _ in 0...header.count {
            try Task.checkCancellation()
            values.append(try readGradientColors(reader: &reader))
        }
        let easings = try readEasings(header: header, dimensions: 1, reader: &reader)
        return try makeProperty(header: header, values: values, easings: easings)
    }

    /// 先读两计数，再alpha与RGB；position保留源Float精度，空表/重复原位置不宽容修补。
    mutating func readGradientColors(reader: inout PAGByteReader) throws -> SourceGradientColors {
        try Task.checkCancellation()
        let offset = reader.position
        try budget.reserve(128)
        let alphaCount = Int(try reader.readEncodedUInt32())
        let colorCount = Int(try reader.readEncodedUInt32())
        guard alphaCount > 0, colorCount > 0 else {
            throw PAGError.invalidFile(reason: "emptyGradientStops", offset: offset)
        }
        guard alphaCount <= 4096, colorCount <= 4096 else { throw PAGError.resourceLimitExceeded("maximumGradientStops") }
        // 计数已限制到4096，以下乘加可表示；短载荷不能驱动双表或排序缓冲分配。
        guard alphaCount * 5 + colorCount * 7 <= reader.remainingByteCount else {
            throw PAGError.truncatedData(offset: reader.position)
        }
        try budget.reserve(count: alphaCount + colorCount, stride: 64)
        var alphas: [SourceAlphaStop] = []
        var colors: [SourceColorStop] = []
        alphas.reserveCapacity(alphaCount)
        colors.reserveCapacity(colorCount)
        for _ in 0..<alphaCount {
            try Task.checkCancellation()
            try budget.reserve(16)
            alphas.append(try SourceAlphaStop(position: readGradientPosition(reader: &reader),
                midpoint: readGradientMidpoint(reader: &reader), opacity: reader.readUInt8()))
        }
        for _ in 0..<colorCount {
            try Task.checkCancellation()
            try budget.reserve(16)
            colors.append(try SourceColorStop(position: readGradientPosition(reader: &reader),
                midpoint: readGradientMidpoint(reader: &reader), color: StaticAttributes.color(from: &reader)))
        }
        let sortedAlpha = try sortedGradientStops(alphas, position: \.position)
        let sortedColors = try sortedGradientStops(colors, position: \.position)
        try Task.checkCancellation()
        return SourceGradientColors(alphaStops: sortedAlpha, colorStops: sortedColors)
    }

    /// GRADIENT_PRECISION为Float(0.00002)，先在Float中相乘，不用Double乘后再舍入。
    private func readGradientPosition(reader: inout PAGByteReader) throws -> Float {
        Float(try reader.readUInt16()) * Float(0.00002)
    }

    /// 源编码可超过1，但当前中点合同只接受0...1；超限明确未支持，不能静默夹值。
    private func readGradientMidpoint(reader: inout PAGByteReader) throws -> Float {
        let value = try readGradientPosition(reader: &reader)
        guard value <= 1 else { throw PAGError.unsupportedFeature("gradientMidpointRange") }
        return value
    }

    /// 双缓冲有界归并；每次比较/移动检查取消并计费，排序后拒绝源码未固定次序的等键。
    private mutating func sortedGradientStops<Value>(_ input: [Value], position: (Value) -> Float) throws -> [Value] {
        // 两个可写缓冲都先计费；初始COW共享不能成为漏计后续复制的理由。
        try budget.reserve(count: input.count, stride: 128)
        var source = input
        var destination = input
        var width = 1
        while width < input.count {
            var lower = 0
            while lower < input.count {
                let middle = min(lower + width, input.count)
                let upper = min(lower + width * 2, input.count)
                var left = lower, right = middle
                for output in lower..<upper {
                    try Task.checkCancellation()
                    try budget.reserve(16)
                    let usesLeft: Bool
                    if right == upper { usesLeft = true }
                    else if left == middle { usesLeft = false }
                    else {
                        try budget.reserve(16)
                        usesLeft = position(source[left]) <= position(source[right])
                    }
                    if usesLeft { destination[output] = source[left]; left += 1 }
                    else { destination[output] = source[right]; right += 1 }
                }
                lower = upper
            }
            swap(&source, &destination)
            width *= 2
        }
        for index in 1..<source.count {
            try Task.checkCancellation()
            try budget.reserve(16)
            guard position(source[index - 1]) != position(source[index]) else {
                throw PAGError.unsupportedFeature("gradientDuplicateSourceStops")
            }
        }
        return source
    }
}
