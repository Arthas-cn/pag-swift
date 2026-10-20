/// 蒙版编码模式；这里只保留源码枚举，不代表所有模式已经接入绘制。
enum SourceMaskMode: UInt8, Sendable {
    /// 不参与蒙版裁剪，但路径仍可能被文本路径等引用。
    case none = 0
    /// 将路径加入蒙版范围；普通路径分支对应Union。
    case add = 1
    /// 从已有范围减去路径；首条有效蒙版有额外反向规则。
    case subtract = 2
    /// 与已有范围取交集。
    case intersect = 3
    /// 上游普通路径分支按Union处理，保留与Add不同的源身份。
    case lighten = 4
    /// 上游普通路径分支按Intersect处理，不在字段阶段模拟透明度混合。
    case darken = 5
    /// 对已有范围执行XOR，与Subtract的单向减法不同。
    case difference = 6
    /// 上游保留的Accum模式，普通路径分支按Union处理。
    case accumulate = 7
}

/// 图层蒙版的不可变源字段；当前仅内部读取和求值，不附加到场景或生成显示命令。
struct SourceMask: Sendable {
    /// 原始引用ID，允许0；后续效果/文本引用与绘制列表是不同职责。
    let id: UInt32
    /// 原始反向填充标记，首项Subtract的取反留给求值层。
    let isInverted: Bool
    /// 文件编码的模式，未知枚举在读取时失败。
    let mode: SourceMaskMode
    /// 完整路径及动画，缺省为空路径，不在字段阶段裁掉开放轮廓。
    let path: SourceProperty<SourcePath>
    /// tag14为nil；tag84始终保留轨道，即使缺省零点也不能归一化成nil。
    let feather: SourceProperty<ScenePoint>?
    /// 原始0...255不透明度轨道，缺省255；动画身份影响整层渲染分支。
    let opacity: SourceProperty<UInt8>
    /// 有限Float来源的扩张距离轨道，允许负值，不是形状整体缩放。
    let expansion: SourceProperty<Double>
}
