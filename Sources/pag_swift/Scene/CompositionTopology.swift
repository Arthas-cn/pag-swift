/// 已验证的控制父链与轨道遮罩邻层索引；保持源编码顺序，避免逐帧重建引用。
struct CompositionTopology: Sendable {
    /// 每个源图层对应的父层数组下标；nil 表示没有控制父层，数组与 layers 等长。
    let parents: [Int?]
    /// 每层已安装的遮罩源编码下标；首层或None为nil，inactive源仍可被引用。
    let trackMatteSources: [Int?]
}
