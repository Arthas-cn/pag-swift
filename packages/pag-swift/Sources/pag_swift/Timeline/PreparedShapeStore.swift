/// 一个播放准备结果独占的后台动态形状缓存；保存解析几何和不可变材料，不存显示像素或跨播放器共享可变状态。
actor PreparedShapeStore {
    /// 固定文档中的动态源层模板；数组共享不可变源数据，键不接受其他文档混入。
    private let templates: [SourceLayerReference: [SourceShape]]
    /// 最多四项缓存的总保守成本；0关闭留存，仍允许当前请求准备。
    private let maximumBytes: Int
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
        // 只借用现有四项LRU中的同源对象；候选数组在分配前计费，失败期间不移动旧条目。
        try budget.reserve(count: entries.count, stride: 16)
        let candidates = entries.reversed().compactMap { $0.key.source == key.source ? $0.layer : nil }
        let layer = try ShapePreparation.prepare(elements, at: key.frame, reusing: candidates, budget: &budget)
        try Task.checkCancellation()
        // 超大单条仍可供当前帧使用；不为一个无法留存的结果挤掉所有已有缓存。
        if layer.estimatedBytes <= maximumBytes {
            while entries.count >= 4 || retainedBytes > maximumBytes - layer.estimatedBytes {
                let removed = entries.removeFirst()
                retainedBytes -= removed.layer.estimatedBytes
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
