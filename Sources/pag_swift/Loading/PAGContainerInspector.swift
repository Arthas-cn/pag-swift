import Foundation

/// 内部容器检查结果，只证明头部和顶层标签边界闭合，不能作为 PAGFile 返回。
struct PAGContainerInspection: Sendable {
    /// 非加密且被当前读取器接受的容器版本。
    let version: UInt8
    /// 声明且已核对完整的 body 字节范围。
    let bodyRange: Range<Int>
    /// 文件顶层标签清单，包含末尾的 End，不解释未知标签的语义。
    let tags: [PAGTagHeader]

    /// 保存完成结构校验的探查信息，不构造场景或纹理。
    init(version: UInt8, bodyRange: Range<Int>, tags: [PAGTagHeader]) {
        self.version = version
        self.bodyRange = bodyRange
        self.tags = tags
    }
}

/// 按上游已证实的容器布局检查输入，尚未承担公开载入职责。
enum PAGContainerInspector {
    /// 在并发执行域检查内存快照；截断、未知版本/压缩、预算超限和取消分别失败。
    @concurrent static func inspect(
        _ data: Data, limits: PAGLoadLimits = .standard
    ) async throws -> PAGContainerInspection {
        try Task.checkCancellation()
        guard data.count <= limits.maximumFileBytes else {
            throw PAGError.resourceLimitExceeded("maximumFileBytes")
        }
        // 首先限制复制后的读取器成本，避免读取攻击性长度前就申请超大快照。
        guard data.count <= limits.maximumDecodedBytes else {
            throw PAGError.resourceLimitExceeded("maximumDecodedBytes")
        }
        // 证据：Codec.cpp::ReadBodyBytes，固定头 9 字节，最少还必须有 2 字节 End。
        guard data.count >= 11 else { throw PAGError.truncatedData(offset: data.count) }
        var reader = PAGByteReader(data: data)
        let magic = [try reader.readUInt8(), try reader.readUInt8(), try reader.readUInt8()]
        guard magic == [0x50, 0x41, 0x47] else {
            throw PAGError.invalidFile(reason: "invalidMagic", offset: 0)
        }
        let version = try reader.readUInt8()
        // 上游 EncryptedVersion 与 KnownVersion 都是 3；3 不能作为普通版本继续读。
        guard version != 3 else { throw PAGError.unsupportedFeature("encryptedContainer") }
        guard version < 3 else { throw PAGError.unsupportedVersion(Int(version)) }
        let bodyLength = Int(try reader.readUInt32())
        let compression = try reader.readUInt8()
        // 证据：codec/CompressionAlgorithm.h::UNCOMPRESSED = 'U'，不是数值零。
        guard compression == 0x55 else {
            throw PAGError.unsupportedFeature("containerCompression:\(compression)")
        }
        let bodyStart = reader.position
        guard bodyLength <= reader.remainingByteCount else {
            throw PAGError.truncatedData(offset: data.count)
        }
        guard bodyLength == reader.remainingByteCount else {
            throw PAGError.invalidFile(reason: "trailingContainerBytes", offset: bodyStart + bodyLength)
        }
        var body = try reader.readSubreader(byteCount: bodyLength)
        var tags: [PAGTagHeader] = []
        let maximumTagCount = (limits.maximumDecodedBytes - data.count) / MemoryLayout<PAGTagHeader>.stride
        while true {
            if tags.count.isMultiple(of: 256) { try Task.checkCancellation() }
            guard tags.count < maximumTagCount else {
                throw PAGError.resourceLimitExceeded("maximumDecodedBytes")
            }
            let header = try PAGTagHeader.read(from: &body)
            tags.append(header)
            if header.code == 0 {
                guard body.remainingByteCount == 0 else {
                    throw PAGError.invalidFile(reason: "trailingTagBytes", offset: body.position)
                }
                break
            }
            // 此阶段只检查边界，不把未知标签或完整清单误称为已支持的 PAG 场景。
            try body.skip(byteCount: header.payloadRange.count)
        }
        try Task.checkCancellation()
        return PAGContainerInspection(version: version, bodyRange: bodyStart..<data.count, tags: tags)
    }
}
