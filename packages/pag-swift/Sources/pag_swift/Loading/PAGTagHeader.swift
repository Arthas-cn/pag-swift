/// 单个标签的字节边界，不表示标签内容已经被解码或可渲染。
struct PAGTagHeader: Sendable, Equatable {
    /// 上游 TagCode 的原始数值，0 为 End；内部探查保留未知数值。
    let code: UInt16
    /// 标签头开始的绝对文件偏移。
    let offset: Int
    /// 完整载荷在原文件内的右开范围，End 的范围为空。
    let payloadRange: Range<Int>

    /// 读取并验证标签头和载荷边界，返回后游标仍停在载荷起点。
    static func read(from reader: inout PAGByteReader) throws -> PAGTagHeader {
        let offset = reader.position
        // 证据：libpag src/codec/TagHeader.cpp::ReadTagHeader。
        // 低六位是短长度，63 表示后面另有一个小端 UInt32 完整长度。
        let word = try reader.readUInt16()
        let code = word >> 6
        let shortLength = word & 63
        let length = shortLength == 63 ? Int(try reader.readUInt32()) : Int(shortLength)
        let start = reader.position
        guard length <= reader.remainingByteCount else {
            throw PAGError.truncatedData(offset: start)
        }
        guard code != 0 || length == 0 else {
            throw PAGError.invalidFile(reason: "endTagHasPayload", offset: offset)
        }
        return PAGTagHeader(code: code, offset: offset, payloadRange: start..<(start + length))
    }

    /// 仅保存已经检查过的标签范围，由静态读取方法调用。
    private init(code: UInt16, offset: Int, payloadRange: Range<Int>) {
        self.code = code
        self.offset = offset
        self.payloadRange = payloadRange
    }
}
