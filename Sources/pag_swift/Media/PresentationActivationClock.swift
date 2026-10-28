import Synchronization

/// 单播放场景的附加呈现时间；短锁允许有效系统呈现与播放许可在同一线性化点提交。
final class PresentationActivationClock: Sendable {
    /// 实例字典只在 Mutex 内访问；相同内容跨编辑快照共享独立的同步计时条目。
    private let entries: Mutex<[PAGLayerID: PresentationActivationEntry]>

    /// 创建尚未激活的场景时钟；不从墙钟或根合成位置推算已播放时间。
    init() { entries = Mutex([:]) }

    /// 构造仅共享指定内容计时条目的新快照，条目自身负责同步。
    private init(entries: [PAGLayerID: PresentationActivationEntry]) { self.entries = Mutex(entries) }

    /// 读取本实例累计可见播放时间；尚未实际激活时始终返回零。
    func elapsed(for id: PAGLayerID, at activeTime: PAGTime) -> PAGTime {
        entries.withLock { $0[id] }?.elapsed(at: activeTime) ?? .zero
    }

    /// 报告一个有效呈现帧的完整活动实例集合；缺席实例冻结，再次出现时续播。
    func activate(_ ids: [PAGLayerID], at activeTime: PAGTime) {
        let visible = Set(ids)
        let snapshot = entries.withLock { entries in
            for id in ids where entries[id] == nil { entries[id] = PresentationActivationEntry() }
            return entries
        }
        for (id, entry) in snapshot { entry.present(isActive: visible.contains(id), at: activeTime) }
    }

    /// 同内容编辑复用指定实例，预先建立未激活条目以捕获准备期间的首次有效呈现。
    func retaining(_ ids: Set<PAGLayerID>) -> PresentationActivationClock {
        let kept = entries.withLock { entries in
            var kept: [PAGLayerID: PresentationActivationEntry] = [:]
            for id in ids {
                let entry = entries[id] ?? PresentationActivationEntry()
                entries[id] = entry
                kept[id] = entry
            }
            return kept
        }
        return PresentationActivationClock(entries: kept)
    }

    /// 有效替换帧到达后移除单个占位实例，后续再次出现从零开始。
    func deactivate(_ id: PAGLayerID) { entries.withLock { $0[id] = nil } }

    /// 显式回卷或新安装清除本快照计时条目；调用方须先撤销旧播放许可。
    func reset() { entries.withLock { $0.removeAll() } }
}

/// 一个实例的可见时间累计；其它 tag 更新时可安全共享，不共享整个可变场景。
private final class PresentationActivationEntry: Sendable {
    /// 计时三元组始终原子读取/修改。
    private let state = Mutex(PresentationActivationState())

    /// 无有效呈现前累计值为零，活动起点为空。
    init() {}

    /// 活动区间使用播放器累计时间作差，暂停/整窗口隐藏时输入本身冻结。
    func elapsed(at time: PAGTime) -> PAGTime {
        state.withLock { state in
            let delta = state.start.map { max(0, time.microseconds - $0) } ?? 0
            return PAGTime(microseconds: state.accumulated + delta)
        }
    }

    /// 上一可见区间先结算，再决定是否开始下一段；不可见间隔不计入累计值。
    func present(isActive: Bool, at time: PAGTime) {
        let now = max(0, time.microseconds)
        state.withLock { state in
            // 同一许可内回调时间单调；旧快照共享条目时仍拒绝倒退输入，防止重复累计。
            guard now >= state.last else { return }
            if let start = state.start { state.accumulated += max(0, now - start) }
            state.start = isActive ? now : nil
            state.last = now
        }
    }
}

/// 仅存于单实例锁中的微秒标量，不保存任务或媒体资源。
private struct PresentationActivationState {
    /// 已结算的有效可见时长；不包含当前仍在推进的区间。
    var accumulated: Int64 = 0
    /// 当前可见区间起点；nil 表示尚未激活或正在不可见区间。
    var start: Int64?
    /// 最近有效呈现帧的辅助时间，拒绝迟到倒退采样。
    var last: Int64 = 0
}
