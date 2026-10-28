/// 文档内容身份与根到本次图层实例的路径；调用方不能自行构造源 ID。
public struct PAGLayerID: Sendable, Hashable {
    /// 完整 PAG 字节的内容身份，跨文件查找必须相符。
    let document: DocumentIdentity
    /// 每一级同级唯一的源图层 ID；同一预合成的不同引用产生不同路径。
    let path: [UInt32]
}

/// 图层的语义类别；具体绘制资源由内部场景保管。
public enum PAGLayerKind: Sendable, Hashable {
    /// 不产生像素，但可作为父变换控制节点。
    case null
    /// 单色区域。
    case solid
    /// 文字、字形及相关样式生成的内容。
    case text
    /// 路径与形状操作生成的内容。
    case shape
    /// 原始图片或可替换素材。
    case image
    /// 对另一合成的实例引用，直接子层由 children 提供。
    case precomposition
}

/// 只读图层实例快照，O(1) 共享不可变文档，不携带播放器状态。
public struct PAGLayer: Sendable {
    /// 该图层所属的完整不可变文档。
    let storage: DocumentStorage
    /// 已验证的实例数组下标，永远在 storage.instances 内。
    let instanceIndex: Int
    /// 图层物化时的值语义编辑覆盖；后续合成编辑不倒写这个旧值。
    let edits: CompositionEdits

    /// 当前实例在文件内容中的唯一身份，复制快照时保持不变。
    public var id: PAGLayerID { instance.id }
    /// 文件中的原始名称，允许空字符串和重名。
    public var name: String { source.name }
    /// 本层内容的语义种类。
    public var kind: PAGLayerKind { source.content.kind }
    /// 父合成时间轴上的起点，单位微秒，可为负。
    public var startTime: PAGTime { instance.startTime }
    /// 父合成时间轴上可见区间的长度，单位微秒。
    public var duration: PAGTime { instance.duration }
    /// 当前快照的显示开关，不等同于某个时刻一定产生像素。
    public var isVisible: Bool { edits.visibility[id] ?? source.isActive }
    /// 源图层关联的文件级槽位；nil 表示无关联，允许编辑范围另见 PAGFile 索引集合。
    public var editableIndex: Int? {
        storage.catalog.slots[SourceLayerReference(composition: instance.compositionIndex, layer: instance.layerIndex)]
    }
    /// 按上游公开顺序物化直接子层；复杂度 O(n)，n 为直接子层数。
    public var children: [PAGLayer] {
        instance.children.map { PAGLayer(storage: storage, instanceIndex: $0, edits: edits) }
    }

    /// 当前实例的预计算数据；下标只由验证器产生。
    private var instance: LayerInstance { storage.instances[instanceIndex] }
    /// 当前实例引用的源图层，不因预合成复用而复制。
    private var source: SourceLayer {
        storage.compositions[instance.compositionIndex].layers[instance.layerIndex]
    }
}
