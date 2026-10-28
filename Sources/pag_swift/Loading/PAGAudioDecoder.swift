/// 三类合成共用的音频字段读取，完整验证后才保存内部元数据。
extension PAGSceneDecoder {
    /// 按AudioBytes.cpp读取有界容器字节及源起点；零长度仍消费起点，失败不返回部分值。
    mutating func readAudio(reader: inout PAGByteReader) throws -> SourceAudio {
        try Task.checkCancellation()
        try budget.reserve(128)
        let count = Int(try reader.readEncodedUInt32())
        guard count <= reader.remainingByteCount else {
            throw PAGError.truncatedData(offset: reader.position)
        }
        try budget.reserve(count)
        try Task.checkCancellation()
        // DecodeStream::readByteData把零长度映射为nullptr；不能套用视频NAL必须非空的规则。
        let bytes = try count == 0 ? nil : reader.readData(byteCount: count)
        try Task.checkCancellation()
        let start = try StaticAttributes.frame(from: &reader)
        try StaticAttributes.requireEnd(of: reader)
        try Task.checkCancellation()
        return SourceAudio(bytes: bytes, startFrame: start)
    }

    /// 完整消费共同音频标签后才更新暂存；未知标签返回false且不动游标，调用方继续分发。
    mutating func readCompositionMetadata(code: UInt16, reader: inout PAGByteReader,
                                         audio: inout SourceAudio?, markers: inout [SourceMarker]) throws -> Bool {
        switch code {
        case 55:
            let value = try readAudio(reader: &reader)
            // 上游直接赋值，最后一块覆盖；已读成本不退还，避免重复载荷绕过解码预算。
            audio = value
        case 53:
            let values = try readMarkers(reader: &reader, requiresComment: false)
            try StaticAttributes.requireEnd(of: reader)
            try Task.checkCancellation()
            // 标记不依赖音频存在；追加保留文件顺序，不按起点重排或裁剪。
            markers += values
        default:
            return false
        }
        return true
    }
}
