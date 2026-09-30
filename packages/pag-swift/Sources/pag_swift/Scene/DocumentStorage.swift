/// 一次源图层引用的实例记录；资源留在源 DAG，children 仅为实例下标。
struct LayerInstance: Sendable {
    /// 完整内容身份和本次根路径。
    let id: PAGLayerID
    /// 被引用源图层所在合成的下标。
    let compositionIndex: Int
    /// 被引用源图层在编码顺序中的下标。
    let layerIndex: Int
    /// 在父合成时间基下换算后的起点。
    let startTime: PAGTime
    /// 在父合成时间基下换算后的区间长度。
    let duration: PAGTime
    /// 构造时填入、文档发布后不可变的直接子实例下标，按公开顺序。
    var children: [Int]
}

/// 验证后一次性发布的文档存储；所有成员不可变，可在隔离域间共享。
final class DocumentStorage: Sendable {
    /// 完整 PAG 字节摘要。
    let identity: DocumentIdentity
    /// 所有源合成，预合成引用不复制这些内容。
    let compositions: [SourceComposition]
    /// 最后一个源合成为根，依据上游 File::File。
    let rootIndex: Int
    /// 根的预计算正微秒时长。
    let duration: PAGTime
    /// 按公开遍历顺序展开的实例索引，不含源根的人工包装层。
    let instances: [LayerInstance]
    /// 根直接子实例的下标。
    let rootLayers: [Int]
    /// 身份到实例下标的反向表。
    let layerIndices: [PAGLayerID: Int]
    /// 保守逻辑驻留估计，供后续解析缓存计费。
    let estimatedBytes: Int
    /// 字体、原始图片和文件声明的允许索引，永远不包含用户编辑。
    let resources: SourceResources
    /// 编码顺序生成的编辑槽及允许集合，与公开逆序层树相互独立。
    let catalog: EditableCatalog
    /// 与 compositions 一一对应的无环控制父链索引，解析时构造并计入预算。
    let topologies: [CompositionTopology]
    /// 源合成 ID 的查找表；空预合成也能定位，播放不重新构造该字典。
    let compositionIndices: [UInt32: Int]
    /// 文档中出现的源内容种类，载入时汇总；后续能力门禁无需每帧扫描整份源图。
    let contentKinds: Set<PAGLayerKind>
    /// 原始文件的时长适配元数据；当前播放保留原始总时长，不用它控制循环次数。
    let fileTiming: SourceFileTiming

    /// 接受完整验证且一次性构造的记录；不得从未校验输入直接调用。
    init(identity: DocumentIdentity, compositions: [SourceComposition], duration: PAGTime,
         instances: [LayerInstance], rootLayers: [Int], layerIndices: [PAGLayerID: Int], estimatedBytes: Int,
         resources: SourceResources, catalog: EditableCatalog, topologies: [CompositionTopology],
         compositionIndices: [UInt32: Int], contentKinds: Set<PAGLayerKind>, fileTiming: SourceFileTiming) {
        self.identity = identity
        self.compositions = compositions
        rootIndex = compositions.count - 1
        self.duration = duration
        self.instances = instances
        self.rootLayers = rootLayers
        self.layerIndices = layerIndices
        self.estimatedBytes = estimatedBytes
        self.resources = resources
        self.catalog = catalog
        self.topologies = topologies
        self.compositionIndices = compositionIndices
        self.contentKinds = contentKinds
        self.fileTiming = fileTiming
    }
}
