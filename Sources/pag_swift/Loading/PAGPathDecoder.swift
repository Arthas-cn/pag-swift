/// DataTypes.cpp路径位流读取；只建立源路径值，几何和动画求值由Timeline处理。
extension PAGSceneDecoder {
    /// 按ShapePath.cpp读取完整SimpleProperty块，缺省为空路径；尾随、预算和取消均失败。
    mutating func readShapePath(reader: inout PAGByteReader) throws -> SourceProperty<SourcePath> {
        try Task.checkCancellation()
        let flags = try PropertyFlags.read([.property], from: &reader)
        let result = try readPathProperty(flags[0], reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        return result
    }

    /// ReadPath先读全部3位指令再读共用位宽与坐标；不在返回时对齐，以保留后续时间缓动的起始位。
    mutating func readPath(reader: inout PAGByteReader) throws -> SourcePath {
        try Task.checkCancellation()
        try budget.reserve(128)
        let count = Int(try reader.readEncodedUInt32())
        guard count > 0 else { return try SourcePath(verbs: [], points: []) }
        // 计数刚按字节读取完：至少还需全部records和5位位宽，不能让短输入驱动巨量分配。
        let minimumBytes = (count * 3 + 5 + 7) / 8
        guard minimumBytes <= reader.remainingByteCount else { throw PAGError.truncatedData(offset: reader.position) }
        try budget.reserve(count: count, stride: 128)
        var records: [UInt32] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            records.append(try reader.readUnsignedBits(count: 3))
        }
        let width = try reader.readBitWidth()
        var verbs: [SourcePathVerb] = []
        var points: [ScenePoint] = []
        var last = ScenePoint.zero
        for record in records {
            try Task.checkCancellation()
            switch record {
            case 0:
                // Close只改变verb；压缩游标仍保留末端点，不回到最近Move，和绘制游标不同。
                verbs.append(.close)
            case 1, 2:
                verbs.append(record == 1 ? .move : .line)
                last = try packedPoint(width: width, precision: 0.05, reader: &reader)
                points.append(last)
            case 3:
                verbs.append(.line)
                last = ScenePoint(x: Double(Float(try reader.readSignedBits(count: width)) * 0.05), y: last.y)
                points.append(last)
            case 4:
                verbs.append(.line)
                last = ScenePoint(x: last.x, y: Double(Float(try reader.readSignedBits(count: width)) * 0.05))
                points.append(last)
            case 5, 6, 7:
                verbs.append(.cubic)
                // Curve01省略第一控制点，Curve10省略第二控制点；后者复制的是刚读出的终点。
                if record == 5 { points.append(last) }
                let reads = record == 7 ? 3 : 2
                for _ in 0..<reads {
                    last = try packedPoint(width: width, precision: 0.05, reader: &reader)
                    points.append(last)
                }
                if record == 6 { points.append(last) }
            default:
                throw SceneValidator.invalid("invalidPathRecord")
            }
        }
        return try SourcePath(verbs: verbs, points: points)
    }
}
