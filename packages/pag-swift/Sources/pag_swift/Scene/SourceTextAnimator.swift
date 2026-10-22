/// tag70中按编码顺序保留的选择器；只承载源轨道，不负责字形绘制。
enum SourceTextSelector: Sendable {
    /// 由71的范围、形状和缓和轨道共同确定每个字形的影响因子。
    case range(SourceTextRangeSelector)
    /// 由80的时间、空间相位和摆动量确定每个字形的影响因子。
    case wiggly(SourceTextWigglySelector)
}

/// tag71的完整原始属性；百分比、字符分组等即使上游当前渲染器未消费也不能丢失。
struct SourceTextRangeSelector: Sendable {
    /// 选择区间的起点轨道，源默认0。
    let start: SourceProperty<Double>
    /// 选择区间的终点轨道，源默认1。
    let end: SourceProperty<Double>
    /// 同时平移起点和终点的轨道，源默认0。
    let offset: SourceProperty<Double>
    /// 范围单位的源枚举，0为百分比、1为索引。
    let units: UInt8
    /// 分组依据的源枚举，0...3对应字符、非空字符、词和行。
    let basedOn: UInt8
    /// 多个选择器叠加方式的离散轨道，源默认Add=1。
    let mode: SourceProperty<UInt8>
    /// 范围因子的带符号乘数，源默认1。
    let amount: SourceProperty<Double>
    /// 范围轮廓的源枚举，0...5对应方形到平滑。
    let shape: UInt8
    /// 源平滑度轨道；当前上游RangeRenderer不消费，仍完整保留。
    let smoothness: SourceProperty<Double>
    /// 三角形峰值一侧的缓和量，源默认0。
    let easeHigh: SourceProperty<Double>
    /// 三角形基底一侧的缓和量，源默认0。
    let easeLow: SourceProperty<Double>
    /// 是否打乱字形索引；源BitFlag默认false。
    let randomizeOrder: Bool
    /// 打乱顺序的UInt16种子轨道，源默认0。
    let randomSeed: SourceProperty<UInt16>
}

/// tag80的完整摆动选择器属性；逐帧求值前不把相位折算为常量。
struct SourceTextWigglySelector: Sendable {
    /// 与其它选择器叠加方式的离散轨道，源默认Intersect=3。
    let mode: SourceProperty<UInt8>
    /// 摆动上限，源默认1。
    let maxAmount: SourceProperty<Double>
    /// 摆动下限，源默认-1。
    let minAmount: SourceProperty<Double>
    /// 分组依据的源枚举，0...3。
    let basedOn: UInt8
    /// 每秒摆动频率，源默认2。
    let wigglesPerSecond: SourceProperty<Double>
    /// 相邻字形的相关度，源默认0.5。
    let correlation: SourceProperty<Double>
    /// 时间相位偏移，源默认0。
    let temporalPhase: SourceProperty<Double>
    /// 空间相位偏移，源默认0。
    let spatialPhase: SourceProperty<Double>
    /// 锁定维度的离散布尔轨道，源默认false。
    let lockDimensions: SourceProperty<Bool>
    /// 摆动相位的UInt16随机种子轨道，源默认0。
    let randomSeed: SourceProperty<UInt16>
}

/// 一个tag70动画器的源轨道；属性缺席与编码了默认值必须可区分。
struct SourceTextAnimator: Sendable {
    /// 按71/80实际出现顺序排列的因子选择器；空数组表示全字形因子1。
    let selectors: [SourceTextSelector]
    /// 字距加在字形前、后或两侧的离散轨道；只有字距量存在时才消费。
    let trackingType: SourceProperty<UInt8>?
    /// 每字形字距增量；nil表示这一动画器不改变字距。
    let trackingAmount: SourceProperty<Double>?
    /// 文字填充色轨道；当前上游文字动画渲染器不消费，但字节必须保留。
    let fillColor: SourceProperty<SceneColor>?
    /// 文字描边色轨道；当前上游文字动画渲染器不消费，但字节必须保留。
    let strokeColor: SourceProperty<SceneColor>?
    /// 选择器控制的二维位置轨道；nil表示不改变位置。
    let position: SourceProperty<ScenePoint>?
    /// 选择器控制的二维比例轨道；nil表示不改变缩放。
    let scale: SourceProperty<ScenePoint>?
    /// 选择器控制的角度轨道；nil表示不改变旋转。
    let rotation: SourceProperty<Double>?
    /// 选择器控制的UInt8透明度轨道；nil表示保留原字形alpha。
    let opacity: SourceProperty<UInt8>?
}
