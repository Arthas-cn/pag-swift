import Foundation

/// 单场景可选替换素材的终态失败表；短锁只存领域错误，不跨帧重复解码坏素材。
final class OptionalMediaFailures: @unchecked Sendable {
    /// 错误映射受同一短锁保护，GPU/解码均不在锁内运行。
    private let lock = NSLock()
    /// 实例级终态错误；相同素材的不同图层仍可各自选择占位。
    private var failures: [PAGLayerID: PAGError] = [:]

    /// 返回该实例首次记录的错误；nil表示可继续请求素材帧。
    func failure(for id: PAGLayerID) -> PAGError? { lock.withLock { failures[id] } }

    /// 只记录首次终态错误，后续帧不覆盖原始诊断或重复启动解码。
    func record(_ error: PAGError, for id: PAGLayerID) {
        lock.withLock {
            if failures[id] == nil { failures[id] = error }
        }
    }
}
