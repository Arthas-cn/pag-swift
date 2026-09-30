/// 已验证的同级控制父链索引；保持源编码顺序，避免播放每帧重建 ID 字典。
struct CompositionTopology: Sendable {
    /// 每个源图层对应的父层数组下标；nil 表示没有控制父层，数组与 layers 等长。
    let parents: [Int?]
}
