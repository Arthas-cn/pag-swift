import Foundation
import Testing
@testable import pag_swift

/// 读取原语用真实夹具和独立字节片段验收；片段不是伪造的完整 PAG 文件。
struct PAGByteReaderTests {
    /// 真实 red 的合成字段验证小端、符号编码、帧数与浮点，预期来自源码调研。
    @Test func readsRealCompositionAttributes() throws {
        var reader = PAGByteReader(data: try PAGFixtures.data(named: "red.pag"))
        try reader.skip(byteCount: 77)
        #expect(try reader.readEncodedInt32() == 720)
        #expect(try reader.readEncodedInt32() == 1280)
        #expect(try reader.readEncodedUInt64() == 450)
        #expect(try reader.readFloat32() == 30)
        #expect(reader.position == 87)
        try reader.skip(byteCount: 19)
        #expect(try reader.readUTF8String() == "Shape Layer 1")
        #expect(reader.position == 120)
    }

    /// 真实文件长标签头验证 UInt16/UInt32 小端读取和绝对偏移。
    @Test func readsRealExtendedTagHeader() throws {
        var reader = PAGByteReader(data: try PAGFixtures.data(named: "red.pag"))
        try reader.skip(byteCount: 66)
        let header = try PAGTagHeader.read(from: &reader)
        #expect(header.code == 2)
        #expect(header.offset == 66)
        #expect(header.payloadRange == 72..<163)
        #expect(reader.position == 72)
    }

    /// 可变有符号整数使用符号与绝对值，最低位为一且绝对值零时仍为零。
    @Test func signedVarintsAreNotZigZag() throws {
        var reader = PAGByteReader(data: Data([0, 1, 2, 3, 4, 5]))
        for expected: Int32 in [0, 0, 1, -1, 2, -2] {
            #expect(try reader.readEncodedInt32() == expected)
        }
    }

    /// 每种无符号整数的完整位宽均可读取，有符号格式的最大绝对值也不会溢出。
    @Test func varintsPreserveTheirFullBitWidth() throws {
        var reader32 = PAGByteReader(data: Data([0xff, 0xff, 0xff, 0xff, 0x0f]))
        #expect(try reader32.readEncodedUInt32() == .max)
        let wide = Data(Array(repeating: UInt8(0xff), count: 9) + [0x01])
        var reader64 = PAGByteReader(data: wide)
        #expect(try reader64.readEncodedUInt64() == .max)
        var signed = PAGByteReader(data: wide)
        #expect(try signed.readEncodedInt64() == -Int64.max)
    }

    /// 末字节高位溢出与超过最大字节数的续接编码都必须失败。
    @Test func overflowingVarintsFail() {
        var reader32 = PAGByteReader(data: Data([0xff, 0xff, 0xff, 0xff, 0x10]))
        #expect(throws: PAGError.invalidFile(reason: "variableIntegerOverflow", offset: 0)) {
            try reader32.readEncodedUInt32()
        }
        var reader64 = PAGByteReader(data: Data(Array(repeating: 0xff, count: 10)))
        #expect(throws: PAGError.invalidFile(reason: "variableIntegerOverflow", offset: 0)) {
            try reader64.readEncodedUInt64()
        }
        var continued = PAGByteReader(data: Data(Array(repeating: 0x80, count: 5)))
        #expect(throws: PAGError.invalidFile(reason: "variableIntegerOverflow", offset: 0)) {
            try continued.readEncodedUInt32()
        }
    }

    /// 缺少续接字节的编码是截断，不得把已读部分当成成功整数。
    @Test func truncatedVarintFails() {
        var reader = PAGByteReader(data: Data([0x80]))
        #expect(throws: PAGError.truncatedData(offset: 1)) {
            try reader.readEncodedUInt64()
        }
    }

    /// 位流跨字节时保持低位优先，并在读取完整字节时跳过当前 padding。
    @Test func bitOrderAndByteAlignmentMatchUpstream() throws {
        var reader = PAGByteReader(data: Data([0xad, 0x32, 0x7a]))
        #expect(try reader.readUnsignedBits(count: 6) == 45)
        #expect(try reader.readUnsignedBits(count: 6) == 10)
        #expect(reader.position == 2)
        #expect(try reader.readUInt8() == 0x7a)
        #expect(reader.remainingByteCount == 0)
    }

    /// 位字段使用补码符号扩展，与可变整数的符号/绝对值编码分开。
    @Test func signedBitsExtendSign() throws {
        var short = PAGByteReader(data: Data([0b111]))
        #expect(try short.readSignedBits(count: 3) == -1)
        var full = PAGByteReader(data: Data([0, 0, 0, 0x80]))
        #expect(try full.readSignedBits(count: 32) == .min)
    }

    /// 位读取预检失败不消费输入；非法位数也必须失败而不执行不合法移位。
    @Test func bitReadsAreBounded() throws {
        var reader = PAGByteReader(data: Data([0xab]))
        #expect(throws: PAGError.truncatedData(offset: 0)) {
            try reader.readUnsignedBits(count: 9)
        }
        #expect(throws: PAGError.invalidArgument("bitCount")) {
            try reader.readSignedBits(count: 0)
        }
        #expect(throws: PAGError.invalidArgument("bitCount")) {
            try reader.readUnsignedBits(count: 33)
        }
        #expect(try reader.readUInt8() == 0xab)
        #expect(try reader.readUnsignedBits(count: 0) == 0)
    }

    /// 子流不能越过载荷边界，失败后仍可从原位置读取，父流游标独立。
    @Test func subreadersKeepPayloadBoundaries() throws {
        var parent = PAGByteReader(data: Data([1, 2, 3, 4]))
        try parent.skip(byteCount: 1)
        var child = try parent.readSubreader(byteCount: 2)
        #expect(throws: PAGError.truncatedData(offset: 1)) { try child.skip(byteCount: 3) }
        #expect(try child.readUInt16() == 0x0302)
        #expect(throws: PAGError.truncatedData(offset: 3)) { try child.readUInt8() }
        #expect(try parent.readUInt8() == 4)
    }

    /// 极大跳过长度必须先按剩余长度验证，不能让偏移加法溢出。
    @Test func byteCountsRejectOverflowAndNegatives() {
        var reader = PAGByteReader(data: Data([1]))
        #expect(throws: PAGError.truncatedData(offset: 0)) { try reader.skip(byteCount: .max) }
        #expect(throws: PAGError.invalidArgument("byteCount")) { try reader.skip(byteCount: -1) }
    }

    /// 字符串正确解码 Unicode；缺少零终止或非法 UTF-8 都必须失败。
    @Test func stringsRequireTerminatorAndValidUTF8() throws {
        var unicode = PAGByteReader(data: Data(Array("图层".utf8) + [0]))
        #expect(try unicode.readUTF8String() == "图层")
        var truncated = PAGByteReader(data: Data([0x41]))
        #expect(throws: PAGError.truncatedData(offset: 1)) { try truncated.readUTF8String() }
        var invalid = PAGByteReader(data: Data([0xc3, 0x28, 0]))
        #expect(throws: PAGError.invalidFile(reason: "invalidUTF8", offset: 0)) {
            try invalid.readUTF8String()
        }
    }
}
