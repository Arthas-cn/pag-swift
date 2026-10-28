/// 可替换源槽的内容类别；图片槽也接受保留动态属性的 PAGImage。
public enum PAGContentKind: String, Sendable, Hashable {
    /// 文件中允许编辑的文本源，所有嵌套实例共享文字和布局。
    case text
    /// 文件中允许编辑的图片资源，同一资源的所有实例共享替换。
    case image
}

/// 已验证文档中一个可替换源槽的只读描述；不携带宿主内容或屏幕变换。
public struct PAGContentSlot: Sendable, Hashable, Identifiable {
    /// 当前文档内唯一的稳定业务键；碰撞消解由库完成，调用方不必拼接。
    public let tag: String
    /// 可接受的内容种类，隐藏和恢复适用于两种槽位。
    public let kind: PAGContentKind
    /// 文件原有可编辑索引；仅在同一种类内唯一，可用于解释源槽身份。
    public let sourceIndex: Int
    /// 此源槽所有非空图层名，按字典序去重；无名槽为空数组。
    public let sourceNames: [String]
    /// 源图层局部坐标中的文本框或图片逻辑尺寸；点文字没有有效框时为 nil。
    /// 共享源槽的实例可有不同变换，此值不是某个实例的屏幕尺寸。
    public let size: PAGSize?
    /// 根合成展开后引用此源槽的实例数，不是 provider 请求次数。
    public let instanceCount: Int
    /// 集合接口使用文档内的业务键；跨文件使用时由宿主关联文档身份。
    public var id: String { tag }
}

/// 不可变文件的业务内容入口；目录不保存任何可变替换状态。
extension PAGFile {
    /// 返回允许编辑的真实源槽；文字在前、图片在后，各按源索引升序。复杂度 O(n log n)。
    public var contentSlots: [PAGContentSlot] { composition.contentSlots }
}

/// 合成编辑与文件共享同一槽位身份，替换或隐藏不会改变目录。
extension PAGComposition {
    /// 返回源槽描述，覆盖嵌套合成并按源去重；复杂度 O(n log n)，n 为图层实例数。
    public var contentSlots: [PAGContentSlot] { dynamicSlotRecords().map(\.slot) }

    /// 一次扫描建立允许源槽及名称归属；派生键必须避开所有真实名称和已分配键。
    func dynamicSlotRecords() -> [DynamicSlotRecord] {
        var groups: [DynamicSlotKey: [Int]] = [:]
        var owners: [String: Set<String>] = [:]
        for (position, instance) in storage.instances.enumerated() {
            let reference = SourceLayerReference(composition: instance.compositionIndex, layer: instance.layerIndex)
            let source = storage.compositions[reference.composition].layers[reference.layer]
            let key: DynamicSlotKey?
            if let index = storage.catalog.slots[reference],
               source.content.kind == .text, storage.catalog.textSet.contains(index) {
                key = DynamicSlotKey(kind: .text, index: index)
            } else if let index = storage.catalog.slots[reference],
                      source.content.kind == .image, storage.catalog.imageSet.contains(index) {
                key = DynamicSlotKey(kind: .image, index: index)
            } else { key = nil }
            if let key { groups[key, default: []].append(position) }
            if !source.name.isEmpty {
                // 非编辑层同名也算歧义，不能让业务 tag 意外暗示替换了整个同名集合。
                owners[source.name, default: []].insert(key?.alias ?? "noneditable")
            }
        }
        var used = Set(owners.keys)
        return groups.keys.sorted().map { key in
            let indices = groups[key] ?? []
            let names = Set(indices.map { position in
                let instance = storage.instances[position]
                return storage.compositions[instance.compositionIndex].layers[instance.layerIndex].name
            }.filter { !$0.isEmpty }).sorted()
            let tag: String
            if names.count == 1, let name = names.first, owners[name] == [key.alias] {
                tag = name
            } else {
                var candidate = key.alias
                var suffix = 0
                while used.contains(candidate) {
                    suffix += 1
                    candidate = "\(key.alias)#\(suffix)"
                }
                tag = candidate
            }
            used.insert(tag)
            let size: PAGSize?
            switch key.kind {
            case .text:
                let source = storage.catalog.texts[key.index]
                size = source.isBoxText ? try? PAGSize(width: source.boxSize.x, height: source.boxSize.y) : nil
            case .image:
                size = storage.resources.images[storage.catalog.imageIDs[key.index]]?.logicalSize
            }
            return DynamicSlotRecord(slot: PAGContentSlot(tag: tag, kind: key.kind, sourceIndex: key.index,
                sourceNames: names, size: size, instanceCount: indices.count), instances: indices)
        }
    }
}

/// 目录中的源槽与实例位置；仅内部编辑使用，公开接口不要求宿主遍历实例。
struct DynamicSlotRecord: Sendable {
    /// 可跨隔离传给宿主的不可变业务描述。
    let slot: PAGContentSlot
    /// 同一源槽的全部实例位置，来自已验证的 DocumentStorage。
    let instances: [Int]
}

/// 在文字和图片索引命名空间之间消除歧义，不增加 PAG 格式字段。
private struct DynamicSlotKey: Hashable, Comparable {
    /// 决定索引所处的源目录以及稳定展示顺序。
    let kind: PAGContentKind
    /// 在对应目录中的允许源索引。
    let index: Int
    /// 无可用唯一名称时的派生键基础形式。
    var alias: String { "\(kind.rawValue):\(index)" }

    /// 文字槽先于图片槽，同类保持源索引顺序。
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind == .text }
        return lhs.index < rhs.index
    }
}
