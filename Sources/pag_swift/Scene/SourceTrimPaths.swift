/// 有file.h::TrimPathsType证据的路径裁剪范围；未知枚举由解码边界拒绝。
enum SourceTrimMode: UInt8, Sendable {
    /// 每条已出现的路径独立使用同一裁剪比例，不合计它们的长度。
    case simultaneously = 0
    /// 按已有路径的累计长度分配范围，反向时还倒转路径列表的测量顺序。
    case individually = 1
}

/// TrimPaths的不可变源轨道；只保存字段，不在解码期间改变路径或生成显示几何。
struct SourceTrimPaths: Sendable {
    /// 裁剪起点的原始Float比例；有限值不限制在0...1，也不除以100。
    let start: SourceProperty<Double>
    /// 裁剪终点比例；省略时按上游历史兼容值100保存，与显式1不同。
    let end: SourceProperty<Double>
    /// 偏移角度轨道，单位为度，取余和反向留给源帧求值。
    let offset: SourceProperty<Double>
    /// 文件中固定的逐路径或累计路径方式，不随播放时间变化。
    let mode: SourceTrimMode

    /// 任一轨道包含关键帧即为动画，所有端点值相同也不能降为常量。
    var isAnimated: Bool { start.isAnimated || end.isAnimated || offset.isAnimated }
}
