/// Loader actor 独占的 O(1) 双向 LRU；仅保存不可变解析结果，不保存输入文件句柄。
struct ParsedFileCache {
    /// 留存计费字节上限；零禁用留存，构造前已验证非负。
    let byteLimit: Int
    /// 内容键到条目；previous/next 也用键表示，避免对象环。
    private var entries: [ParseKey: ParsedCacheEntry] = [:]
    /// 最近使用条目的键，空缓存为 nil。
    private var newest: ParseKey?
    /// 最久未使用条目的键，空缓存为 nil。
    private var oldest: ParseKey?
    /// 当前条目的保守计费总和，不包含调用者单独持有的已淘汰文件。
    private(set) var byteCount = 0

    /// 当前留存条目数，供内部诊断和预算验证。
    var count: Int { entries.count }

    /// 命中后移到最近使用端；未命中不改变顺序。
    mutating func value(for key: ParseKey) -> PAGFile? {
        guard let entry = entries[key] else { return nil }
        moveToNewest(key)
        return entry.file
    }

    /// 插入并淘汰最旧条目；超大文档仍可返回给调用者，但不进入留存缓存。
    mutating func insert(_ file: PAGFile, for key: ParseKey) {
        remove(key)
        let charge = file.storage.estimatedBytes.addingReportingOverflow(128)
        guard !charge.overflow, charge.partialValue <= byteLimit else { return }
        let cost = charge.partialValue
        while byteCount > byteLimit - cost, let key = oldest { remove(key) }
        entries[key] = ParsedCacheEntry(file: file, bytes: cost, previous: nil, next: newest)
        if let newest { entries[newest]?.previous = key }
        else { oldest = key }
        newest = key
        byteCount += cost
    }

    /// 删除指定键并修复相邻链接，不影响调用方已经持有的文档值。
    mutating func remove(_ key: ParseKey) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        if let previous = entry.previous { entries[previous]?.next = entry.next }
        else { newest = entry.next }
        if let next = entry.next { entries[next]?.previous = entry.previous }
        else { oldest = entry.previous }
        byteCount -= entry.bytes
    }

    /// 释放所有条目和索引容量；flight 的失效由 loader 单独处理。
    mutating func removeAll() {
        entries.removeAll()
        newest = nil
        oldest = nil
        byteCount = 0
    }

    /// 已命中条目从原位置摘下后插到头部，保持其他条目相对顺序。
    private mutating func moveToNewest(_ key: ParseKey) {
        guard key != newest, let entry = entries[key] else { return }
        if let previous = entry.previous { entries[previous]?.next = entry.next }
        if let next = entry.next { entries[next]?.previous = entry.previous }
        else { oldest = entry.previous }
        entries[key]?.previous = nil
        entries[key]?.next = newest
        if let newest { entries[newest]?.previous = key }
        newest = key
    }
}

/// 一个 LRU 节点；键链接只在所属 loader actor 内修改。
private struct ParsedCacheEntry {
    /// 完整验证过的不可变文档，不含编辑或播放状态。
    let file: PAGFile
    /// 文档保守估计加条目成本，必须为正。
    let bytes: Int
    /// 更近使用条目的键；nil 表示当前节点为头。
    var previous: ParseKey?
    /// 更早使用条目的键；nil 表示当前节点为尾。
    var next: ParseKey?
}
