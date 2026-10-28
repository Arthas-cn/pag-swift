/// Repeater的编码层叠顺序；未知Value字节必须在解码时失败。
enum SourceRepeaterOrder: UInt8, Sendable {
    /// 第一份在上，后续复制品依次向下放置。
    case below = 0
    /// 后续复制品依次插到此前复制品上方。
    case above = 1
}

/// tag26的不可变源属性；只保存轨道，不在解码时展开形状节点。
struct SourceRepeater: Sendable {
    /// 原始Above/Below枚举，决定复制结果的覆盖顺序。
    let order: SourceRepeaterOrder
    /// 复制份数，可含小数或负值；负值保持原组。
    let copies: SourceProperty<Double>
    /// 每份progress的固定偏移，不改变ceilf计算的份数。
    let offset: SourceProperty<Double>
    /// 复制变换的局部锚点，缺省为原点。
    let anchor: SourceProperty<ScenePoint>
    /// 每份progress对应的位置增量，缺省为(100,100)。
    let position: SourceProperty<ScenePoint>
    /// 两轴幂缩放的底数，缺省为单位向量。
    let scale: SourceProperty<ScenePoint>
    /// 每份progress对应的旋转增量，单位为度。
    let rotation: SourceProperty<Double>
    /// 透明度插值起点，文件数值域为0...255。
    let startOpacity: SourceProperty<UInt8>
    /// 透明度插值终点，文件数值域为0...255。
    let endOpacity: SourceProperty<UInt8>

    /// 任一轨道有关键帧即不能将源内容标成静态。
    var isAnimated: Bool {
        copies.isAnimated || offset.isAnimated || anchor.isAnimated || position.isAnimated ||
            scale.isAnimated || rotation.isAnimated || startOpacity.isAnimated || endOpacity.isAnimated
    }
}
