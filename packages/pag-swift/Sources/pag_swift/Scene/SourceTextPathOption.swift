/// tag69的原始文字沿路径轨道；只保存同层mask引用ID，不在解码时求路径几何。
struct SourceTextPathOption: Sendable {
    /// 0表示未编码引用；非零ID须在同一文字层mask列表中查找。
    let maskID: UInt32
    /// 是否沿相反方向消费引用的mask路径，允许离散动画。
    let reversed: SourceProperty<Bool>
    /// 是否让字形基线跟随路径切线旋转；false保留原方向。
    let perpendicular: SourceProperty<Bool>
    /// 是否按整条路径强制分散文字，而非采用普通段落对齐。
    let forceAlignment: SourceProperty<Bool>
    /// 路径开始处的有符号距离，动画取当前层帧。
    let firstMargin: SourceProperty<Double>
    /// 路径末尾的有符号距离，动画取当前层帧。
    let lastMargin: SourceProperty<Double>
}
