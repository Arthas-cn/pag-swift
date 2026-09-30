import Foundation

/// PAG 解码的有界只读游标；子流共享不可变字节，不负责解释任何图层语义。
struct PAGByteReader: Sendable {
    /// 整份输入的不可变字节快照，子流通过 COW 共享存储。
    private let bytes: [UInt8]
    /// 本流允许读取的右开终点，保持原始文件偏移以便报告错误。
    private let upperBound: Int
    /// 下一次位读取所在字节，或下一次完整字节读取的起点。
    private var cursor: Int
    /// 当前字节已消费的低位数，合法范围为 0...7。
    private var bitOffset: Int

    /// 从完整字节建立游标；调用方必须在复制前检查文件预算。
    init(data: Data) {
        bytes = Array(data)
        upperBound = data.count
        cursor = 0
        bitOffset = 0
    }

    /// 仅用已验证范围建立共享子流，偏移仍相对于原文件。
    private init(bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        upperBound = range.upperBound
        cursor = range.lowerBound
        bitOffset = 0
    }

    /// 下一次完整字节读取的绝对偏移；未用完的当前字节向上对齐。
    var position: Int { cursor + (bitOffset == 0 ? 0 : 1) }

    /// 对齐后还可读取的完整字节数，不包含当前字节剩余的少量位。
    var remainingByteCount: Int { upperBound - position }

    /// 丢弃当前字节尚未读取的高位，与上游 alignWithBytes 一致。
    mutating func alignToByte() {
        cursor = position
        bitOffset = 0
    }

    /// 读取一个无符号字节，缺少输入时抛带绝对偏移的 truncatedData。
    mutating func readUInt8() throws -> UInt8 {
        let range = try consumeRange(byteCount: 1)
        return bytes[range.lowerBound]
    }

    /// 按上游 DecodeStream.h 指定的小端序读取 UInt16。
    mutating func readUInt16() throws -> UInt16 {
        UInt16(try readFixedUnsigned(byteCount: 2))
    }

    /// 按上游 DecodeStream.h 指定的小端序读取 UInt32。
    mutating func readUInt32() throws -> UInt32 {
        UInt32(try readFixedUnsigned(byteCount: 4))
    }

    /// 读取小端 IEEE 754 浮点位模式；有限性由字段语义层校验。
    mutating func readFloat32() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    /// 读取最多五字节的无符号可变整数，拒绝截断和超出 UInt32 的载荷。
    mutating func readEncodedUInt32() throws -> UInt32 {
        UInt32(try readVariableUnsigned(bitWidth: 32))
    }

    /// 读取最多十字节的无符号可变整数，拒绝截断和超出 UInt64 的载荷。
    mutating func readEncodedUInt64() throws -> UInt64 {
        try readVariableUnsigned(bitWidth: 64)
    }

    /// 按低位符号、其余位绝对值还原有符号整数；不使用 ZigZag 解码。
    mutating func readEncodedInt32() throws -> Int32 {
        // 证据：libpag src/codec/utils/DecodeStream.cpp::readEncodedInt32。
        let encoded = try readEncodedUInt32()
        let magnitude = Int32(encoded >> 1)
        return encoded & 1 == 0 ? magnitude : -magnitude
    }

    /// 按上游 readEncodedInt64 的符号/绝对值编码还原，负零规范化为零。
    mutating func readEncodedInt64() throws -> Int64 {
        let encoded = try readEncodedUInt64()
        let magnitude = Int64(encoded >> 1)
        return encoded & 1 == 0 ? magnitude : -magnitude
    }

    /// 低位优先读取 0...32 位；越界失败前不消费任何位。
    mutating func readUnsignedBits(count: Int) throws -> UInt32 {
        guard (0...32).contains(count) else { throw PAGError.invalidArgument("bitCount") }
        let requiredBytes = (bitOffset + count + 7) / 8
        guard requiredBytes <= upperBound - cursor else {
            throw PAGError.truncatedData(offset: position)
        }
        // 证据：DecodeStream.cpp::readUBits。流内先读每字节低位，结果也从低位拼接。
        var result: UInt32 = 0
        for outputBit in 0..<count {
            let bit = (bytes[cursor] >> bitOffset) & 1
            result |= UInt32(bit) << outputBit
            bitOffset += 1
            if bitOffset == 8 {
                cursor += 1
                bitOffset = 0
            }
        }
        return result
    }

    /// 将 1...32 位补码符号扩展为 Int32；这里与可变整数的符号编码不同。
    mutating func readSignedBits(count: Int) throws -> Int32 {
        guard (1...32).contains(count) else { throw PAGError.invalidArgument("bitCount") }
        let bits = try readUnsignedBits(count: count)
        // 证据：DecodeStream.cpp::readBits。左移后按有符号数右移，保留最高符号位。
        let shift = 32 - count
        return Int32(bitPattern: bits << shift) >> shift
    }

    /// DecodeStream::readNumBits 用五位保存 width-1，结果范围为 1...32，不额外对齐。
    mutating func readBitWidth() throws -> Int {
        Int(try readUnsignedBits(count: 5)) + 1
    }

    /// 读取以零字节结束的完整 UTF-8 字符串；非法编码或缺少结束字节时失败。
    mutating func readUTF8String() throws -> String {
        let start = position
        var end = start
        // 上游 readUTF8String 使用有界零终止串；长字符串的扫描也必须响应取消。
        while end < upperBound, bytes[end] != 0 {
            if (end - start).isMultiple(of: 4096) { try Task.checkCancellation() }
            end += 1
        }
        guard end < upperBound else { throw PAGError.truncatedData(offset: upperBound) }
        guard let value = String(bytes: bytes[start..<end], encoding: .utf8) else {
            throw PAGError.invalidFile(reason: "invalidUTF8", offset: start)
        }
        cursor = end + 1
        bitOffset = 0
        return value
    }

    /// 消费指定字节并创建共享子流；子流不能读到相邻标签的载荷。
    mutating func readSubreader(byteCount: Int) throws -> PAGByteReader {
        let range = try consumeRange(byteCount: byteCount)
        return PAGByteReader(bytes: bytes, range: range)
    }

    /// 复制有界原始载荷供系统资源解码；调用方须在复制前校验预算。
    mutating func readData(byteCount: Int) throws -> Data {
        let range = try consumeRange(byteCount: byteCount)
        return Data(bytes[range])
    }

    /// 跳过已知长度的数据；负长度或超出子流范围时失败。
    mutating func skip(byteCount: Int) throws {
        _ = try consumeRange(byteCount: byteCount)
    }

    /// 验证完整字节范围后才移动游标，避免 start + count 在检查前溢出。
    private mutating func consumeRange(byteCount: Int) throws -> Range<Int> {
        guard byteCount >= 0 else { throw PAGError.invalidArgument("byteCount") }
        let start = position
        guard byteCount <= upperBound - start else {
            throw PAGError.truncatedData(offset: start)
        }
        cursor = start + byteCount
        bitOffset = 0
        return start..<cursor
    }

    /// 仅供固定宽度读取使用，逐字节拼接以避免未对齐内存载入。
    private mutating func readFixedUnsigned(byteCount: Int) throws -> UInt64 {
        let range = try consumeRange(byteCount: byteCount)
        var value: UInt64 = 0
        for (index, byte) in bytes[range].enumerated() {
            value |= UInt64(byte) << (index * 8)
        }
        return value
    }

    /// 按上游每字节七位载荷/最高位续接的规则读取，并加上明确的位宽溢出校验。
    private mutating func readVariableUnsigned(bitWidth: Int) throws -> UInt64 {
        let start = position
        var value: UInt64 = 0
        for shift in stride(from: 0, to: bitWidth, by: 7) {
            let byte = try readUInt8()
            let payload = UInt64(byte & 0x7f)
            let available = min(7, bitWidth - shift)
            guard payload < UInt64(1) << available else {
                throw PAGError.invalidFile(reason: "variableIntegerOverflow", offset: start)
            }
            value |= payload << shift
            if byte & 0x80 == 0 { return value }
        }
        // 已消费所有合法位宽仍有续接位，不能像宽容解析器那样截掉高位后继续。
        throw PAGError.invalidFile(reason: "variableIntegerOverflow", offset: start)
    }
}
