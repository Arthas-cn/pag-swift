/// Unicode 标量边界与 CoreText cluster 的验证映射；避免把视觉顺序中的索引直接相减。
struct TextClusters {
    /// UTF-16 边界到 UTF-8 偏移；代理对中间为−1，不能作为合法 cluster 起点。
    private let byteOffsets: [Int]
    /// 每个系统 cluster 在逻辑顺序中的结束位置，重复视觉索引共享同一范围。
    private let ends: [Int: Int]
    /// 源 UTF-8 字节，只用于区分单字节 ASCII、空格与换行，不复制每个片段的 String。
    private let bytes: [UInt8]

    /// 在分配前计量输入与索引；范围超出字符串或落入代理对中间时拒绝系统结果。
    init(text: String, indices: [Int], budget: inout FramePlanBudget) throws {
        let length = text.utf16.count
        try budget.reserve(count: length + 1, stride: 16)
        try budget.reserve(count: text.utf8.count, stride: 1)
        try budget.reserve(count: indices.count, stride: 128)
        var offsets = [Int](repeating: -1, count: length + 1)
        var utf16 = 0
        var utf8 = 0
        for scalar in text.unicodeScalars {
            try Task.checkCancellation()
            offsets[utf16] = utf8
            utf16 += scalar.value > 0xffff ? 2 : 1
            utf8 += scalar.utf8.count
        }
        offsets[length] = utf8
        for index in indices {
            guard index >= 0, index < length, offsets[index] >= 0 else {
                throw SceneValidator.invalid("invalidTextCluster")
            }
        }
        let sorted = Set(indices).sorted()
        var ends: [Int: Int] = [:]
        for (index, start) in sorted.enumerated() {
            try Task.checkCancellation()
            ends[start] = index + 1 < sorted.count ? sorted[index + 1] : length
        }
        byteOffsets = offsets
        self.ends = ends
        bytes = Array(text.utf8)
    }

    /// 返回已验证的逻辑 UTF-16 范围及字节特征；未知系统索引明确失败。
    func cluster(at index: Int) throws -> TextCluster {
        guard let end = ends[index] else { throw SceneValidator.invalid("invalidTextCluster") }
        let first = byteOffsets[index]
        let count = byteOffsets[end] - first
        return TextCluster(range: index..<end, isSingleByte: count == 1,
                           isSpace: count == 1 && bytes[first] == 32, isLineBreak: bytes[first] == 10)
    }
}

/// PAG 布局需要的 cluster 特征；不把 Swift 扩展字素簇个数当成 glyph 数量。
struct TextCluster: Sendable {
    /// 对应原字符串的合法 UTF-16 右开范围。
    let range: Range<Int>
    /// UTF-8 恰好一个字节时，竖排按上游的 ASCII 旋转规则处理。
    let isSingleByte: Bool
    /// 是否为单个普通空格，用于 A 字形边界修正。
    let isSpace: Bool
    /// 首字节是否为换行，布局消费该 glyph 但不绘制。
    let isLineBreak: Bool
}
