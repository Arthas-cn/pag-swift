import CryptoKit
import Foundation

/// 完整字节的 SHA-256 身份；文档与实例共用，不依赖路径或文件时间戳。
struct DocumentIdentity: Sendable, Hashable {
    /// 固定 32 字节摘要，数组副本共享不可变存储。
    let digest: [UInt8]

    /// 分块计算 prefix 与 data 顺序拼接后的摘要，不分配拼接副本；空输入也响应取消。
    init(data: Data, prefix: Data = Data()) throws {
        try Task.checkCancellation()
        var hash = SHA256()
        // 避免一次不可取消地处理整个大文件；块大小不参与格式语义。
        for region in [prefix, data] {
            for offset in stride(from: 0, to: region.count, by: 262_144) {
                try Task.checkCancellation()
                // Data 的 slice 可能保留非零 startIndex，不能把相对偏移直接当下标。
                let start = region.index(region.startIndex, offsetBy: offset)
                let end = region.index(start, offsetBy: min(262_144, region.count - offset))
                hash.update(data: region[start..<end])
            }
        }
        digest = Array(hash.finalize())
    }

    /// 接受逐块哈希的最终摘要，供不应整文件留存在内存中的外部媒体使用。
    init(sha256: SHA256.Digest) { digest = Array(sha256) }
}
