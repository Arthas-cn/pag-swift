/// 网格缓存保活的不可变路径来源；不持有字体、CoreGraphics 或 Metal 可变对象。
enum RenderGeometrySource: Sendable {
    /// 一次 nonzero 形状填充的全部解析轮廓。
    case shape(ShapeGeometry)
    /// 已经提取的单个填充或描边字形轮廓。
    case glyph(GlyphOutline)
    /// 普通蒙版的有限nonzero路径；反向标记由显示作用域持有，不进入几何缓存键。
    case mask(SourcePath)
    /// 非零扩张或多条普通路径的有序Boolean；每项扩张值也进入缓存键。
    case maskExpression(SampledMaskExpression)

    /// 仅当来源对象仍被保活时有效的身份，不使用内容摘要重新遍历整条路径。
    var identity: GeometrySourceIdentity {
        switch self {
        case let .shape(value): .object(ObjectIdentifier(value))
        case let .glyph(value): .object(ObjectIdentifier(value))
        case let .mask(value): .object(ObjectIdentifier(value))
        case let .maskExpression(value): .mask(value.terms.map {
            MaskTermIdentity(path: ObjectIdentifier($0.path), mode: $0.mode.rawValue,
                             inverted: $0.isInverted, expansionBits: $0.expansion.bitPattern)
        })
        }
    }

    /// 来源数组的保守留存计费；极端乘法溢出表示不可缓存，不截断为较小数值。
    var estimatedBytes: Int? {
        let count: Int
        let stride: Int
        switch self {
        case let .shape(value): return value.estimatedBytes
        case let .mask(value): return value.estimatedBytes
        case let .maskExpression(value): return value.estimatedBytes
        case let .glyph(value): count = value.elements.count; stride = 128
        }
        let array = count.multipliedReportingOverflow(by: stride)
        let total = array.partialValue.addingReportingOverflow(128)
        return array.overflow || total.overflow ? nil : total.partialValue
    }

    /// 使用同一预算完成折线化与 nonzero 填充分解，失败不返回半份资源。
    func prepare(precision: GeometryPrecision, budget: inout GeometryBudget) throws -> RenderMesh {
        let contours: [[ScenePoint]]
        switch self {
        case let .shape(value): contours = try PathFlattening.shape(value, tolerance: precision.tolerance, budget: &budget)
        case let .glyph(value): contours = try PathFlattening.glyph(value, tolerance: precision.tolerance, budget: &budget)
        case let .mask(value): contours = try PathFlattening.sourcePath(value, tolerance: precision.tolerance, budget: &budget)
        case let .maskExpression(value):
            try budget.reserve(value.terms.count, stride: 64)
            // 与普通来源一样先支付最终RenderMesh外壳；不能因本分支提前返回漏收。
            try budget.reserve(stride: 128)
            var operands: [MaskBooleanOperand] = []
            operands.reserveCapacity(value.terms.count)
            for term in value.terms {
                try budget.consume()
                let contours = try PathFlattening.sourcePath(term.path, tolerance: precision.tolerance,
                                                              budget: &budget)
                let stroke = try MaskExpansionGeometry.strokeContours(
                    for: term.path, expansion: term.expansion, original: contours,
                    tolerance: precision.tolerance, budget: &budget)
                operands.append(MaskBooleanOperand(contours: contours, strokeContours: stroke,
                                                   expansion: term.expansion, mode: term.mode,
                                                   isInverted: term.isInverted))
            }
            let result = try MaskBooleanTessellation.prepare(operands, budget: &budget)
            guard result.isInverted == value.isInverted else {
                throw PAGError.renderingFailure("maskBooleanOutside")
            }
            // PathKit对零verb撤销clip：远场false的空网格可能隐藏或不裁剪，必须拒绝；
            // 远场true的空网格两种路径都让全部内容可见，可安全保留补集标记。
            guard result.isInverted || !result.mesh.vertices.isEmpty else {
                throw PAGError.unsupportedFeature("maskBooleanEmptyResult")
            }
            return result.mesh
        }
        try budget.reserve(stride: 128)
        return try NonzeroTessellation.prepare(contours, budget: &budget)
    }
}

/// 网格来源的语义身份；多路径键保留完整有序列表，不借表达式临时对象地址命中。
enum GeometrySourceIdentity: Hashable {
    /// 单个既有不可变来源的对象身份。
    case object(ObjectIdentifier)
    /// 全部普通蒙版路径及其操作的有序身份。
    case mask([MaskTermIdentity])
}

/// 一条普通蒙版源项的缓存键片段；顺序由外层数组固定。
struct MaskTermIdentity: Hashable {
    /// 被缓存条目强保活的源路径对象身份。
    let path: ObjectIdentifier
    /// 原始mode数值，不将首项不同模式提前合并成同一个键。
    let mode: UInt8
    /// 本项反向位，可改变布尔结果与远场。
    let inverted: Bool
    /// 当前帧Float扩张位型；同一路径不同扩张不能共享网格。
    let expansionBits: UInt32
}

/// 后台渲染 owner 独占的有界 O(1) LRU；这里只缓存网格，不缓存最终画面或逐帧副本。
struct RenderGeometryCache {
    /// 网格、保活来源和条目的总预算；零禁用留存，已有调用者仍可持有返回的网格。
    let byteLimit: Int
    /// 源身份与精度档到条目，条目中的来源保活防止 ObjectIdentifier 被新对象复用。
    private var entries: [GeometryCacheKey: GeometryCacheEntry] = [:]
    /// 最近使用条目，空缓存时为 nil。
    private var newest: GeometryCacheKey?
    /// 最久未使用条目，空缓存时为 nil。
    private var oldest: GeometryCacheKey?
    /// 当前留存的保守成本，不包含调用者已经取走的淘汰资源。
    private(set) var byteCount = 0
    /// 当前缓存网格数量；同一路径的不同精度档分别计数。
    var count: Int { entries.count }

    /// 默认最多留存 64 MiB；负值不是禁用缓存，明确报告非法参数。
    init(byteLimit: Int = 64 * 1024 * 1024) throws {
        guard byteLimit >= 0 else { throw PAGError.invalidArgument("geometryCacheBytes") }
        self.byteLimit = byteLimit
    }

    /// 获取最终显示矩阵所需的精度网格；命中也检查取消和预算，平移不影响缓存键。
    mutating func mesh(for source: RenderGeometrySource, transform: SceneAffine,
                       budget: inout GeometryBudget) throws -> RenderMesh {
        try budget.consume()
        if case .maskExpression(let expression) = source {
            // 复合键会分配路径身份数组；命中也须为构键工作和临时空间付费。
            try budget.consume(expression.terms.count)
            try budget.reserve(expression.terms.count, stride: 32)
        }
        let precision = try GeometryPrecision(transform: transform)
        let key = GeometryCacheKey(identity: source.identity, precision: precision)
        try Task.checkCancellation()
        if let entry = entries[key] {
            // 已缓存不代表新的请求可以绕开更低资源上限；来源数据本身不重复复制。
            try budget.reserve(stride: entry.mesh.estimatedBytes)
            moveToNewest(key)
            return entry.mesh
        }
        let mesh = try source.prepare(precision: precision, budget: &budget)
        try Task.checkCancellation()
        insert(mesh, source: source, for: key)
        return mesh
    }

    /// 清空所有保活来源与网格；外部使用中的不可变网格不受影响。
    mutating func removeAll() {
        entries.removeAll()
        newest = nil
        oldest = nil
        byteCount = 0
    }

    /// 在完整准备成功后留存，超大条目返回给调用者但不挤掉所有已有缓存。
    private mutating func insert(_ mesh: RenderMesh, source: RenderGeometrySource, for key: GeometryCacheKey) {
        guard let sourceBytes = source.estimatedBytes else { return }
        let retained = sourceBytes.addingReportingOverflow(mesh.estimatedBytes)
        let total = retained.partialValue.addingReportingOverflow(256)
        guard !retained.overflow, !total.overflow, total.partialValue <= byteLimit else { return }
        let cost = total.partialValue
        while byteCount > byteLimit - cost, let oldest { remove(oldest) }
        entries[key] = GeometryCacheEntry(source: source, mesh: mesh, bytes: cost, previous: nil, next: newest)
        if let newest { entries[newest]?.previous = key }
        else { oldest = key }
        newest = key
        byteCount += cost
    }

    /// 摘除最旧节点或指定节点，链接都用值键避免形成对象引用环。
    private mutating func remove(_ key: GeometryCacheKey) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        if let previous = entry.previous { entries[previous]?.next = entry.next }
        else { newest = entry.next }
        if let next = entry.next { entries[next]?.previous = entry.previous }
        else { oldest = entry.previous }
        byteCount -= entry.bytes
    }

    /// 命中移到最近使用端，其余条目的相对顺序保持不变。
    private mutating func moveToNewest(_ key: GeometryCacheKey) {
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

/// 仅由不可变来源身份和几何精度组成；颜色、透明度与平移均在编码时应用。
private struct GeometryCacheKey: Hashable {
    /// 由条目 source 保活的对象身份。
    let identity: GeometrySourceIdentity
    /// 由线性变换决定的细分档位。
    let precision: GeometryPrecision
}

/// 一个网格 LRU 条目，所有链接由所属 RenderOwner 串行修改。
private struct GeometryCacheEntry {
    /// 必须强持有原对象，不能仅用一个可能被复用的地址作为缓存键。
    let source: RenderGeometrySource
    /// 完整且不可变的三角形资源。
    let mesh: RenderMesh
    /// 此条目全部保守计费，必定为正。
    let bytes: Int
    /// 更近使用的节点；nil 表示头部。
    var previous: GeometryCacheKey?
    /// 更早使用的节点；nil 表示尾部。
    var next: GeometryCacheKey?
}
