import Foundation

/// 单播放场景的附加呈现起点；短锁允许GPU有效完成与播放许可在同一线性化点提交。
final class PresentationActivationClock: @unchecked Sendable {
    /// 只保护少量起点标量，不在锁内解码、求值或等待GPU。
    private let lock = NSLock()
    /// 每个实际显示过的附加内容实例首次激活微秒，移除或回卷时删除。
    private var starts: [PAGLayerID: Int64] = [:]

    /// 首次有效提交后建立零点；暂停、seek或根循环只读取冻结/累计的辅助时间。
    func elapsed(for id: PAGLayerID, at activeTime: PAGTime) -> PAGTime {
        let now = max(0, activeTime.microseconds)
        return lock.withLock {
            guard let start = starts[id] else { return .zero }
            return PAGTime(microseconds: max(0, now - start))
        }
    }

    /// 有效GPU提交后才给本次实际选中的附加内容建立起点，重复提交不回拨。
    func activate(_ ids: [PAGLayerID], at activeTime: PAGTime) {
        let now = max(0, activeTime.microseconds)
        lock.withLock {
            for id in ids where starts[id] == nil { starts[id] = now }
        }
    }

    /// 有效替换帧已经到达时解除单个附加内容的时钟。
    func deactivate(_ id: PAGLayerID) { lock.withLock { _ = starts.removeValue(forKey: id) } }

    /// 显式回卷后清除全部辅助起点；调用方须先撤销旧播放许可。
    func reset() { lock.withLock { starts.removeAll() } }
}
