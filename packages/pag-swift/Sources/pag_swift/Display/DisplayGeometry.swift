/// 显示层的纯值几何；像素分配向上取整，不把零布局或非法倍率送入 CAMetalLayer。
struct DisplayGeometry: Sendable, Equatable {
    /// 宿主提供的正逻辑点尺寸。
    let size: PAGSize
    /// 逻辑点到显示像素的有限正倍率。
    let scale: Double
    /// 向上取整后的正像素宽度，受内部资源策略限制。
    let pixelWidth: Int
    /// 向上取整后的正像素高度，受内部资源策略限制。
    let pixelHeight: Int

    /// 校验并建立显示几何；默认上限属于库策略，实际分配仍须检查 Metal 返回值。
    init(size: PAGSize, scale: Double, maximumDimension: Int = 16_384,
         maximumPixels: Int = 16_777_216) throws {
        guard scale.isFinite, scale > 0 else { throw PAGError.invalidArgument("scale") }
        guard maximumDimension > 0, maximumPixels > 0 else { throw PAGError.invalidArgument("displayLimits") }
        let width = (size.width * scale).rounded(.up)
        let height = (size.height * scale).rounded(.up)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              let pixelWidth = Int(exactly: width), let pixelHeight = Int(exactly: height) else {
            throw PAGError.invalidArgument("displayPixelSize")
        }
        guard pixelWidth <= maximumDimension, pixelHeight <= maximumDimension,
              UInt128(pixelWidth) * UInt128(pixelHeight) <= UInt128(maximumPixels) else {
            throw PAGError.resourceLimitExceeded("displayPixels")
        }
        self.size = size
        self.scale = scale
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// 某个显示代数的宿主配置；由主 actor 发布副本，不保存父层或设备对象。
struct DisplayTargetConfiguration: Sendable, Equatable {
    /// 最近合法布局；nil 表示尚未收到正尺寸，不能申请 drawable。
    var geometry: DisplayGeometry?
    /// 是否已经由受控接口挂到父层；挂载本身不代表可见。
    var isMounted = false
    /// 调用者明确允许呈现的意图，默认 false。
    var isActive = false
}
