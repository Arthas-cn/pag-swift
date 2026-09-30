/// 可编辑文字与样式值；布局框、方向和原始动画仍属于不可变源场景。
public struct PAGText: Sendable, Hashable {
    /// Unicode 文本，允许空串。
    public var text: String
    /// 字体家族；空串由排版层采用系统默认字体。
    public var fontFamily: String
    /// 字体样式；空串采用该家族默认样式。
    public var fontStyle: String
    /// 合成坐标中的有限正字号；替换时再次校验。
    public var fontSize: Double
    /// 非预乘填充色；nil 表示禁用填充。
    public var fillColor: PAGColor?
    /// 非预乘描边色；nil 表示禁用描边。
    public var strokeColor: PAGColor?
    /// 合成坐标中的有限非负描边宽度。
    public var strokeWidth: Double
    /// 有限行距；源文件中零表示由排版层计算自动行距。
    public var leading: Double
    /// 有限字符间距，保留 PAG 原始单位，由排版层解释。
    public var tracking: Double

    /// 创建样式并校验数值；非法字号/描边/行距/字距抛同名 invalidArgument。
    public init(text: String, fontSize: Double, fontFamily: String = "", fontStyle: String = "",
                fillColor: PAGColor? = nil, strokeColor: PAGColor? = nil, strokeWidth: Double = 0,
                leading: Double = 0, tracking: Double = 0) throws {
        self.text = text
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.fontStyle = fontStyle
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.leading = leading
        self.tracking = tracking
        try validate()
    }

    /// 替换前重新验证可变字段；调用者构造后修改的非法值不能进入新快照。
    func validate() throws {
        guard fontSize.isFinite, fontSize > 0 else { throw PAGError.invalidArgument("fontSize") }
        guard strokeWidth.isFinite, strokeWidth >= 0 else { throw PAGError.invalidArgument("strokeWidth") }
        guard leading.isFinite else { throw PAGError.invalidArgument("leading") }
        guard tracking.isFinite else { throw PAGError.invalidArgument("tracking") }
    }
}
