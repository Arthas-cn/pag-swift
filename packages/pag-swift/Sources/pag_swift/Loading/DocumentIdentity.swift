import CryptoKit
import Foundation

/// 完整字节的 SHA-256 身份；文档与实例共用，不依赖路径或文件时间戳。
struct DocumentIdentity: Sendable, Hashable {
    /// 固定 32 字节摘要，数组副本共享不可变存储。
    let digest: [UInt8]

    /// 分块计算完整内容摘要，取消在每个有界块之间检查。
    init(data: Data) throws {
        var hash = SHA256()
        // 避免一次不可取消地处理整个大文件；块大小不参与格式语义。
        for offset in stride(from: 0, to: data.count, by: 262_144) {
            try Task.checkCancellation()
            // Data 的 slice 可能保留非零 startIndex，不能把相对偏移直接当下标。
            let start = data.index(data.startIndex, offsetBy: offset)
            let end = data.index(start, offsetBy: min(262_144, data.count - offset))
            hash.update(data: data[start..<end])
        }
        digest = Array(hash.finalize())
    }
}
