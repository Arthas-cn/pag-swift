/// 完整验证的不可变 PAG 子集文档；不携带纹理、编辑或播放状态。
public struct PAGFile: Sendable {
    /// 多个文件值共享的已验证源 DAG 和实例索引。
    let storage: DocumentStorage

    /// O(1) 返回原始合成快照；后续编辑只影响调用方持有的合成值。
    public var composition: PAGComposition { PAGComposition(storage: storage) }
    /// 允许编辑的文本索引数量，不一定等于源文本总数。
    public var editableTextCount: Int { storage.catalog.allowedTexts.count }
    /// 允许编辑的图片索引数量，不等于图片图层或实例总数。
    public var editableImageCount: Int { storage.catalog.allowedImages.count }
    /// 升序且无重复的允许文本索引，不能只用数量推导它们。
    public var editableTextIndices: [Int] { storage.catalog.allowedTexts }
    /// 升序且无重复的允许图片索引，可能是原始槽位的子集。
    public var editableImageIndices: [Int] { storage.catalog.allowedImages }

    /// 原始静态图片与实际采样 bitmap 序列的像素尺寸，用于宿主组合自身图片预算。
    /// 静态图按文件资源表计量；bitmap 按内容身份去重，不随预合成实例重复计数。
    /// 不包含宿主替换图、文字纹理、视频缓冲或 GPU 分配，也不解码额外帧。
    public var embeddedImagePixelSizes: [(width: Int, height: Int)] {
        var sizes = storage.resources.images.values.map {
            (width: Int($0.image.size.width), height: Int($0.image.size.height))
        }
        var seen = Set<DocumentIdentity>()
        for composition in storage.compositions {
            // 播放器只采样最后一条 bitmap 序列；同内容的多个合成共享帧存储。
            if let sequence = composition.bitmap?.sequences.last, seen.insert(sequence.identity).inserted {
                sizes.append((width: sequence.width, height: sequence.height))
            }
        }
        return sizes
    }
}

/// 共享完整基础场景的合成快照；不提供任意空合成构造器。
public struct PAGComposition: Sendable {
    /// 只读文档及实例树，复制合成只增加共享引用。
    let storage: DocumentStorage
    /// 当前值独占的 COW 覆盖表；复制合成或物化图层不会共享可变状态。
    var edits = CompositionEdits()

    /// 根合成的有限正逻辑尺寸，O(1)。
    public var size: PAGSize { storage.compositions[storage.rootIndex].size }
    /// 根合成的正微秒时长，O(1)。
    public var duration: PAGTime { storage.duration }
    /// 文件记录的有限正帧率，O(1)。
    public var frameRate: Double { storage.compositions[storage.rootIndex].frameRate }
    /// 按上游公开顺序物化根子层；复杂度 O(n)，n 为根的直接子层数。
    public var layers: [PAGLayer] {
        storage.rootLayers.map { PAGLayer(storage: storage, instanceIndex: $0, edits: edits) }
    }

    /// 通过已建立的身份索引查找，预期 O(1)；外来文档或不存在的路径返回 nil。
    public func layer(withID id: PAGLayerID) -> PAGLayer? {
        guard let index = storage.layerIndices[id] else { return nil }
        return PAGLayer(storage: storage, instanceIndex: index, edits: edits)
    }

    /// 按公开顺序进行深度优先同名查找，返回全部匹配，复杂度 O(n)。
    public func layers(named name: String) -> [PAGLayer] {
        // 实例数组在构造时已按公开顺序前序展开；无需再次递归源 DAG。
        storage.instances.indices.compactMap { index in
            let layer = PAGLayer(storage: storage, instanceIndex: index, edits: edits)
            return layer.name == name ? layer : nil
        }
    }
}
