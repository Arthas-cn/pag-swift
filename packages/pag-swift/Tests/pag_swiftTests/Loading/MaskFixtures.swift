import Foundation
@testable import pag_swift

/// 真实蒙版字段的只读边界记录，不作为完整可播放文件发布。
struct MaskPayload: Sendable {
    /// 相对resources路径，用于追溯原始文件。
    let name: String
    /// 14或84的原始版本。
    let code: UInt16
    /// 完整文件中的绝对右开载荷范围。
    let range: Range<Int>
    /// 只复制该载荷供字段测试，未改写原文件。
    let data: Data
}

/// 蒙版测试夹具；容器遍历仅定位字段，不把跳过其他标签称为解码支持。
enum MaskFixtures {
    /// 验证容器后沿vector/layer边界收集两版本蒙版，包含非Shape图层。
    @concurrent static func payloads() async throws -> [MaskPayload] {
        let root = try PAGFixtures.rootURL().path + "/"
        var values: [MaskPayload] = []
        for url in try PAGFixtures.allPAGURLs() {
            let data = try Data(contentsOf: url)
            let inspection = try await PAGContainerInspector.inspect(data)
            for tag in inspection.tags where tag.code == 2 {
                var reader = PAGByteReader(data: data)
                try reader.skip(byteCount: tag.payloadRange.lowerBound)
                var composition = try reader.readSubreader(byteCount: tag.payloadRange.count)
                _ = try composition.readEncodedUInt32()
                while let (header, payload) = try block(from: &composition) {
                    guard header.code == 5 else { continue }
                    var layer = payload
                    _ = try layer.readUInt8()
                    _ = try layer.readEncodedUInt32()
                    while let (mask, _) = try block(from: &layer) {
                        guard mask.code == 14 || mask.code == 84 else { continue }
                        values.append(MaskPayload(name: String(url.path.dropFirst(root.count)), code: mask.code,
                            range: mask.payloadRange, data: data.subdata(in: mask.payloadRange)))
                    }
                }
            }
        }
        return values
    }

    /// 完整读取独立蒙版载荷并返回实际逻辑预算，保留生产错误及取消。
    static func read(_ data: Data, code: UInt16 = 14, limit: Int = 64 * 1024 * 1024) throws
        -> (mask: SourceMask, cost: Int) {
        var decoder = TrimFixtures.decoder(limit: limit)
        var reader = PAGByteReader(data: data)
        let mask = try decoder.readMask(code: code, reader: &reader)
        return (mask, decoder.budget.used)
    }

    /// 只编码字段片段的Float32小端值，不生成完整PAG。
    static func float(_ value: Float) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) })
    }

    /// 按DecodeStream低位优先规则打包源码定义的属性列表，用于没有真实夹具的字段边界。
    static func bits(_ fields: [(UInt32, Int)]) -> Data {
        var bytes: [UInt8] = []
        var position = 0
        for (value, count) in fields {
            for bit in 0..<count {
                if position.isMultiple(of: 8) { bytes.append(0) }
                bytes[position / 8] |= UInt8((value >> bit) & 1) << (position % 8)
                position += 1
            }
        }
        return Data(bytes)
    }

    /// 标签长度划定子流，End必须位于当前容器末尾，禁止按原始字节搜索tag值。
    private static func block(from reader: inout PAGByteReader) throws -> (PAGTagHeader, PAGByteReader)? {
        let header = try PAGTagHeader.read(from: &reader)
        if header.code == 0 {
            try StaticAttributes.requireEnd(of: reader)
            return nil
        }
        return (header, try reader.readSubreader(byteCount: header.payloadRange.count))
    }
}
