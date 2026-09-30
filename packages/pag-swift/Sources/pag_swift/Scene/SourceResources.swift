/// 文件字体表的一条不可变记录；ID 由表内顺序确定，零是合法索引。
struct SourceFont: Sendable {
    /// 请求的字体家族，可能为空或本机不可用。
    let family: String
    /// 请求的字体样式，不做平台名称替换。
    let style: String
}

/// 原始文本的可编辑样式与不公开修改的排版参数。
struct SourceText: Sendable {
    /// 对应公开 PAGText 的原始值，不包含当前合成覆盖。
    let style: PAGText
    /// 字符基线偏移，保留 PAG 单位。
    let baselineShift: Double
    /// 段落首基线参数，零沿用源默认语义。
    let firstBaseline: Double
    /// 是否使用有界段落文本，而非点文本。
    let isBoxText: Bool
    /// 文本框在图层局部坐标中的位置。
    let boxPosition: ScenePoint
    /// 文本框尺寸；点文本时允许为零。
    let boxSize: ScenePoint
    /// 是否要求合成加粗，独立于字体家族样式。
    let fauxBold: Bool
    /// 是否要求合成斜体，独立于字体家族样式。
    let fauxItalic: Bool
    /// 描边是否覆盖在填充上方。
    let strokeOverFill: Bool
    /// 上游 ParagraphJustification 编码，范围 0...6。
    let justification: UInt8
    /// 文本背景的原始 RGB 色。
    let backgroundColor: SceneColor
    /// 文本背景不透明度，0...255。
    let backgroundAlpha: UInt8
    /// 上游 TextDirection 编码：0 默认、1 水平、2 垂直。
    let direction: UInt8
}

/// 一份原始图片资源；编码像素与 PAG 图层逻辑尺寸/裁边参数分开保存。
struct SourceImage: Sendable {
    /// 原始资源 ID，多个图层引用它时共享同一个 editable image slot。
    let id: UInt32
    /// 完整解码的不可变 WebP 输入像素。
    let image: PAGImage
    /// 含原始透明边界的逻辑尺寸，不一定等于编码像素尺寸。
    let logicalSize: PAGSize
    /// 编码像素相对于逻辑图像的有限正缩放。
    let scaleFactor: Double
    /// 去掉透明边界后的偏移，单位为源逻辑坐标。
    let anchor: ScenePoint
}

/// 文件级不可变资源的构造容器；解码完成后仅通过 DocumentStorage 读取。
struct SourceResources: Sendable {
    /// 文件字体表，按编码索引查找；没有字体表时为空。
    var fonts: [UInt32: SourceFont] = [:]
    /// 文件图片资源；共享 ID 只保存一次完整输入。
    var images: [UInt32: SourceImage] = [:]
    /// nil 表示标签缺失、所有文本槽可编辑；空数组表示显式禁止索引替换。
    var allowedTexts: [Int]?
    /// nil 表示标签缺失、所有图片槽可编辑；空数组表示显式禁止索引替换。
    var allowedImages: [Int]?
    /// 文件缩放表的编码顺序；nil未出现tag94，空数组是已读取的零计数，均不改变原图布局。
    var imageScaleModes: [PAGScaleMode]?
}
