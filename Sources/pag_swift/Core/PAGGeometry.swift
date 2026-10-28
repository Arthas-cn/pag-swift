/// 合成坐标或宿主逻辑点中的有限正尺寸，不包含显示像素倍率。
public struct PAGSize: Sendable, Hashable {
    /// 水平方向的有限正长度。
    public let width: Double
    /// 垂直方向的有限正长度。
    public let height: Double

    /// 拒绝非正或非有限尺寸，错误关联值指出 width 或 height。
    public init(width: Double, height: Double) throws {
        guard width.isFinite, width > 0 else {
            throw PAGError.invalidArgument("width")
        }
        guard height.isFinite, height > 0 else {
            throw PAGError.invalidArgument("height")
        }
        self.width = width
        self.height = height
    }
}

/// 非预乘 sRGB 颜色，渲染阶段再统一转换为需要的像素表示。
public struct PAGColor: Sendable, Hashable {
    /// 闭区间 0...1 内的红色分量。
    public let red: Double
    /// 闭区间 0...1 内的绿色分量。
    public let green: Double
    /// 闭区间 0...1 内的蓝色分量。
    public let blue: Double
    /// 闭区间 0...1 内的不透明度；零表示完全透明。
    public let alpha: Double

    /// 校验四个有限颜色分量，失败时抛出指出具体分量的 invalidArgument。
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) throws {
        for (name, value) in [("red", red), ("green", green), ("blue", blue), ("alpha", alpha)] {
            guard value.isFinite, (0...1).contains(value) else {
                throw PAGError.invalidArgument(name)
            }
        }
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// 最终合成到宿主矩形的居中缩放方式，不改变内部图层布局。
public enum PAGScaleMode: Sendable, Hashable {
    /// 每个合成点对应一个宿主逻辑点，超出目标的部分裁切。
    case none
    /// 分别缩放两个方向以填满目标，允许改变宽高比。
    case stretch
    /// 等比完整显示，留出的区域保持透明。
    case aspectFit
    /// 等比填满目标，裁切超出目标的区域。
    case aspectFill
}
