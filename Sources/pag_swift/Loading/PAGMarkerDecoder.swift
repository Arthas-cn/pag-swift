/// 图层与合成共用的标记字段读取；语境只影响备注校验，不改变字节布局。
extension PAGSceneDecoder {
    /// 按MarkerTag.cpp读取完整列表；只有图层要求非空备注，合成允许空串。
    mutating func readMarkers(reader: inout PAGByteReader, requiresComment: Bool = true) throws -> [SourceMarker] {
        try Task.checkCancellation()
        let count = Int(try reader.readEncodedUInt32())
        // 合成允许空备注；层额外需要非零备注字节，全部时长旗标仍先连续编码。
        let minimumBytes = requiresComment ? 3 : 2
        guard count <= reader.remainingByteCount / minimumBytes,
              (count + 7) / 8 <= reader.remainingByteCount - count * minimumBytes else {
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
            let comment = try reader.readUTF8String(budget: &budget)
            guard !requiresComment || !comment.isEmpty else { throw SceneValidator.invalid("emptyMarkerComment") }
            markers.append(SourceMarker(startFrame: start, durationFrames: duration, comment: comment))
        }
        try Task.checkCancellation()
        return markers
    }
}
