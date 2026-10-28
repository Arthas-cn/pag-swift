/// 一个播放准备结果独占的后台动态形状缓存；保存解析几何和不可变材料，不存显示像素或跨播放器共享可变状态。
actor PreparedShapeStore {
    /// 固定文档中的动态源层模板；数组共享不可变源数据，键不接受其他文档混入。
    private let templates: [SourceLayerReference: [SourceShape]]
    /// 最多64项、每源层最多四项的总保守成本；0关闭留存，仍允许当前请求准备。
    private let maximumBytes: Int
    /// 限制不同源层与历史采样的总条目数，避免仅依赖字节预算保留大量微小结果。
    private let maximumEntries = 64
    /// 每个源层只保留最近四种采样；跨帧复用候选仍为原有的四项上限。
    private let maximumSamplesPerSource = 4
    /// 从最旧到最新的有限条目；小上限允许线性查找，不引入无界帧历史。
    private var entries: [ShapeSampleEntry] = []
    /// 当前缓存持有结果的保守总成本，不计其他帧独立保活的已淘汰结果。
    private(set) var retainedBytes = 0

    /// 安装完整动态模板；负缓存预算失败，调用方已计入模板表的准备预算。
    init(templates: [SourceLayerReference: [SourceShape]], maximumBytes: Int = 64 * 1024 * 1024) throws {
        guard maximumBytes >= 0 else { throw PAGError.invalidArgument("shapeCacheBytes") }
        self.templates = templates
        self.maximumBytes = maximumBytes
    }

    /// 求当前源帧的完整结果，命中也接受本次预算检查；取消/失败不改变条目，无await重入窗口。
    func sample(_ key: ShapeSampleKey, maximumPreparedBytes: Int) throws -> PreparedShapeLayer {
        try Task.checkCancellation()
        guard maximumPreparedBytes > 0 else { throw PAGError.resourceLimitExceeded("maximumFramePlanBytes") }
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let entry = entries[index]
            guard entry.layer.estimatedBytes <= maximumPreparedBytes else {
                throw PAGError.resourceLimitExceeded("maximumFramePlanBytes")
            }
            try Task.checkCancellation()
            entries.remove(at: index)
            entries.append(entry)
            return entry.layer
        }
        guard let elements = templates[key.source] else { throw SceneValidator.invalid("missingPreparedShape") }
        var budget = FramePlanBudget(limit: maximumPreparedBytes)
        // 先按每源上限预付候选数组；其他源层可继续留存，但不能混入本层几何匹配。
        try budget.reserve(count: min(entries.count, maximumSamplesPerSource), stride: 16)
        let candidates = entries.reversed().compactMap { $0.key.source == key.source ? $0.layer : nil }
        let layer = try ShapePreparation.prepare(elements, at: key.frame, reusing: candidates, budget: &budget)
        try Task.checkCancellation()
        // 超大单条仍可供当前帧使用；不为一个无法留存的结果挤掉所有已有缓存。
        if layer.estimatedBytes <= maximumBytes {
            var sameSourceCount = 0
            var oldestSameSource: Int?
            for index in entries.indices where entries[index].key.source == key.source {
                sameSourceCount += 1
                if oldestSameSource == nil { oldestSameSource = index }
            }
            // 先限制本层历史，避免多图层顺序求值时把其它源层仅有的最近结果挤掉。
            if sameSourceCount >= maximumSamplesPerSource, let oldestSameSource {
                remove(at: oldestSameSource)
            }
            while entries.count >= maximumEntries || retainedBytes > maximumBytes - layer.estimatedBytes {
                remove(at: 0)
            }
            entries.append(ShapeSampleEntry(key: key, layer: layer))
            retainedBytes += layer.estimatedBytes
        }
        return layer
    }

    /// 释放owner持有的缓存；外部帧表已经取得的不可变结果仍有效。
    func removeAll() {
        entries.removeAll()
        retainedBytes = 0
    }

    /// 从有限全局 LRU 摘除一个结果并同步计费；调用前下标必须有效。
    private func remove(at index: Int) {
        retainedBytes -= entries.remove(at: index).layer.estimatedBytes
    }
}

/// 一个动态源层的采样身份；所处文档由PreparedShapeStore及FramePlanner固定。
struct ShapeSampleKey: Sendable, Hashable {
    /// 原始源层引用，多次展开的同源实例共享模板。
    let source: SourceLayerReference
    /// 此源合成的整数采样帧，不是根播放微秒或图层相对时间。
    let frame: Int64
}

/// 小型LRU中的一项完整准备结果，淘汰只放弃本owner的强引用。
private struct ShapeSampleEntry {
    /// 源层与采样帧组成的唯一键。
    let key: ShapeSampleKey
    /// 完整求值的指令和复合路径，发布之后不可变。
    let layer: PreparedShapeLayer
}
