import Foundation

/// 已拥有完整字节和内容身份的载入快照，不携带打开文件或可变媒体对象。
struct LoadSnapshot: Sendable {
    /// 此次独立请求取得的不可变字节，缓存命中前也必须重新取得。
    let data: Data
    /// 对完整 data 计算的内容身份。
    let identity: DocumentIdentity

    /// 在并发域检查内存预算并计算摘要，避免哈希阻塞 loader 或 UI actor。
    @concurrent static func prepare(data: Data, limits: PAGLoadLimits) async throws -> LoadSnapshot {
        try Task.checkCancellation()
        guard data.count <= limits.maximumFileBytes else { throw PAGError.resourceLimitExceeded("maximumFileBytes") }
        guard data.count <= limits.maximumDecodedBytes else { throw PAGError.resourceLimitExceeded("maximumDecodedBytes") }
        let identity = try DocumentIdentity(data: data)
        try Task.checkCancellation()
        return LoadSnapshot(data: data, identity: identity)
    }
}

/// 共享解析和缓存的完整键；相同字节仅在相同限制和解码实现下复用。
struct ParseKey: Sendable, Hashable {
    /// 本次完整快照的摘要。
    let identity: DocumentIdentity
    /// 所属 loader 的解码限制，不能跨不同校验强度复用。
    let limits: PAGLoadLimits
    /// 字节解释和支持矩阵的内部版本，扩充不兼容语义时递增。
    let decoderRevision: Int

    /// 从已经准备好的快照建立当前解码器键，不执行 IO 或摘要计算。
    init(snapshot: LoadSnapshot, limits: PAGLoadLimits) {
        identity = snapshot.identity
        self.limits = limits
        decoderRevision = 15
    }
}
