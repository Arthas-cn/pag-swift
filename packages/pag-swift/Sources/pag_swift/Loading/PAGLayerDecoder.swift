/// 基础图层和属性解析；二维变换支持有证据的常量与动画，其他语义逐项扩充。
extension PAGSceneDecoder {
    /// 按 LayerTag.cpp 读取类型、ID 和内部标签；缺失或冲突属性均失败。
    mutating func readLayer(reader: inout PAGByteReader) throws -> SourceLayer {
        try Task.checkCancellation()
        guard sourceLayerCount < limits.maximumLayerCount else {
            throw PAGError.resourceLimitExceeded("maximumLayerCount")
        }
        sourceLayerCount += 1
        try budget.reserve(1024)
        let type = try reader.readUInt8()
        guard (1...6).contains(type) else { throw PAGError.unsupportedFeature("layerType:\(type)") }
        let id = try reader.readEncodedUInt32()
        var attributes: LayerAttributes?
        var transform: SourceTransformProperties?
        var content: SourceLayerContent?
        var shapes: [SourceShape] = []
        var markers: [SourceMarker] = []
        var imageFillRule: SourceImageFillRule?
        while var block = try nextBlock(from: &reader) {
            switch block.code {
            case 6, 52, 62:
                guard attributes == nil else { throw PAGError.invalidFile(reason: "duplicateLayerAttributes", offset: nil) }
                attributes = try readLayerAttributes(code: block.code, reader: &block.reader)
            case 13:
                guard transform == nil else { throw PAGError.invalidFile(reason: "duplicateTransform", offset: nil) }
                transform = try readTransform(reader: &block.reader)
            case 7 where type == 2:
                guard content == nil else { throw PAGError.invalidFile(reason: "duplicateLayerContent", offset: nil) }
                content = try readSolid(reader: &block.reader)
            case 8, 64, 68:
                guard type == 3 else { throw SceneValidator.invalid("textInNonTextLayer") }
                guard content == nil else { throw SceneValidator.invalid("duplicateLayerContent") }
                content = .text(try readText(code: block.code, reader: &block.reader))
            case 11 where type == 5:
                guard content == nil else { throw SceneValidator.invalid("duplicateLayerContent") }
                content = .image(try block.reader.readEncodedUInt32())
            case 12 where type == 6:
                guard content == nil else { throw PAGError.invalidFile(reason: "duplicateLayerContent", offset: nil) }
                content = .precomposition(id: try block.reader.readEncodedUInt32(),
                                         startFrame: try StaticAttributes.frame(from: &block.reader))
            case 15, 16, 19, 20:
                guard type == 4 else { throw PAGError.invalidFile(reason: "shapeInNonShapeLayer", offset: nil) }
                shapes.append(try readShape(code: block.code, reader: &block.reader, depth: 1))
            case 53:
                markers += try readMarkers(reader: &block.reader)
            case 54, 67:
                guard type == 5 else { throw SceneValidator.invalid("imageFillRuleInNonImageLayer") }
                guard imageFillRule == nil else { throw SceneValidator.invalid("duplicateImageFillRule") }
                imageFillRule = try readImageFillRule(code: block.code, reader: &block.reader)
            default:
                throw PAGError.unsupportedFeature("layerTag:\(block.code)")
            }
            try StaticAttributes.requireEnd(of: block.reader)
        }
        guard let attributes, let transform else {
            throw PAGError.invalidFile(reason: "missingLayerAttributesOrTransform", offset: nil)
        }
        if type == 1 { content = .null }
        if type == 4 { content = .shape(shapes) }
        guard let content else { throw PAGError.invalidFile(reason: "missingLayerContent", offset: nil) }
        return SourceLayer(id: id, name: attributes.name, parentID: attributes.parentID,
                           startFrame: attributes.start, durationFrames: attributes.duration,
                           isActive: attributes.isActive, transform: transform, content: content,
                           markers: markers, timing: attributes.timing, imageFillRule: imageFillRule)
    }

    /// 按MarkerTag.cpp读取完整标记列表；重复tag按源码追加，非空备注是Layer::verifyExtra的不变量。
    mutating func readMarkers(reader: inout PAGByteReader) throws -> [SourceMarker] {
        let count = Int(try reader.readEncodedUInt32())
        // 每条至少有起点、一个非零备注字节和结束符；额外连续旗标先按整字节上界保留。
        guard count <= reader.remainingByteCount / 3,
              (count + 7) / 8 <= reader.remainingByteCount - count * 3 else {
            throw PAGError.truncatedData(offset: reader.position)
        }
        try budget.reserve(count: count, stride: 128)
        var durations: [Bool] = []
        // 所有时长旗标连续编码，不能读完一条旗标就对齐并读取该条记录。
        for _ in 0..<count {
            try Task.checkCancellation()
            durations.append(try reader.readUnsignedBits(count: 1) != 0)
        }
        reader.alignToByte()
        var markers: [SourceMarker] = []
        for hasDuration in durations {
            try Task.checkCancellation()
            let start = try StaticAttributes.frame(from: &reader)
            let duration = try hasDuration ? StaticAttributes.frame(from: &reader) : 0
            let comment = try reader.readUTF8String()
            guard !comment.isEmpty else { throw SceneValidator.invalid("emptyMarkerComment") }
            try budget.reserve(comment.utf8.count)
            markers.append(SourceMarker(startFrame: start, durationFrames: duration, comment: comment))
        }
        return markers
    }

    /// 读取LayerAttributes三个版本，保留完整层时间元数据；尚未支持的画面语义仍拒绝。
    mutating func readLayerAttributes(code: UInt16, reader: inout PAGByteReader) throws -> LayerAttributes {
        try Task.checkCancellation()
        var encodings: [AttributeEncoding] = [.flag, .flag]
        if code == 62 { encodings.append(.flag) }
        encodings += [.flag, .flag, .flag, .flag, .flag, .property, .fixed]
        if code != 6 { encodings.append(.flag) }
        let f = try PropertyFlags.read(encodings, from: &reader)
        guard !f[1].exists else { throw PAGError.unsupportedFeature("autoOrientation") }
        if code == 62, f[2].exists { throw PAGError.unsupportedFeature("motionBlur") }
        let p = code == 62 ? 3 : 2
        let parent = try f[p].exists ? reader.readEncodedUInt32() : 0
        let numerator = try f[p + 1].exists ? reader.readEncodedInt32() : 1
        let denominator = try f[p + 1].exists ? reader.readEncodedUInt32() : 1
        guard denominator > 0 else {
            throw SceneValidator.invalid("zeroLayerStretchDenominator")
        }
        let start = try f[p + 2].exists ? StaticAttributes.frame(from: &reader) : 0
        try StaticAttributes.requireDefault(f[p + 3].exists, name: "layerBlendMode", from: &reader)
        try StaticAttributes.requireDefault(f[p + 4].exists, name: "trackMatte", from: &reader)
        // Layer::excludeVaryingRanges只用此轨道阻止静态复用；不能拿它代替预合成或图片素材的时钟。
        let timeRemap = try readScalarProperty(f[p + 5], defaultValue: 0, reader: &reader)
        let duration = try StaticAttributes.frame(from: &reader)
        let name = try code != 6 && f[p + 7].exists ? reader.readUTF8String() : ""
        guard duration > 0 else { throw PAGError.invalidFile(reason: "nonpositiveLayerDuration", offset: nil) }
        return LayerAttributes(isActive: f[0].exists, parentID: parent == 0 ? nil : parent,
            start: start, duration: duration, name: name,
            timing: SourceLayerTiming(stretchNumerator: numerator, stretchDenominator: denominator, timeRemap: timeRemap))
    }

    /// SolidColor.cpp 先读 RGB，再读编码 Int32 尺寸；单色层必须具有正尺寸。
    private func readSolid(reader: inout PAGByteReader) throws -> SourceLayerContent {
        let color = try StaticAttributes.color(from: &reader)
        let width = try reader.readEncodedInt32()
        let height = try reader.readEncodedInt32()
        guard width > 0, height > 0 else { throw PAGError.invalidFile(reason: "invalidSolidSize", offset: nil) }
        return .solid(size: try PAGSize(width: Double(width), height: Double(height)), color: color)
    }
}

/// 基础图层属性暂存，默认行为已在读取时显式建立。
struct LayerAttributes {
    /// BitFlag 直接表示显示开关，零不能改成默认 true。
    let isActive: Bool
    /// 同级父变换源 ID；零编码转为 nil。
    let parentID: UInt32?
    /// 允许为负的起始帧。
    let start: Int64
    /// 正帧区间长度。
    let duration: Int64
    /// V2/V3 可选名称；旧版为空。
    let name: String
    /// 已完整读取的层时间元数据；完整层失败时随暂存值丢弃。
    let timing: SourceLayerTiming
}
