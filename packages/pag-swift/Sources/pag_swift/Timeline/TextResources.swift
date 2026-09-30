import Foundation

/// 一次文本准备的资源代数；同源图层的不同文字编辑不得混用 GPU 或计划资源。
struct TextResourceID: Sendable, Hashable {
    /// 在完整准备成功前产生的不可复用代数，显式共享同一对象时保持不变。
    let generation: UUID
}

/// 实际参与整形的字体诊断，不持有系统字体对象或依赖可变全局注册表。
struct TextFontInfo: Sendable {
    /// CoreText 实际选择的字体家族。
    let family: String
    /// 实际样式名，系统未提供时为空。
    let style: String
    /// 实际 PostScript 名，用于比较运行环境和字体回退。
    let postScriptName: String
    /// 非空请求的家族/样式与实际值不同；空请求采用默认字体不视为失败。
    let substitutesRequest: Bool
}

/// 单个 PAG glyph 的准备结果；轮廓按字体和 glyph ID 共享，位置按实际排版独立。
struct PreparedTextGlyph: Sendable {
    /// 填充轮廓，可能为空；不含字形缩放或基线平移。
    let fill: GlyphOutline
    /// 有效描边的填充轮廓；禁用或小于阈值时为 nil。
    let stroke: GlyphOutline?
    /// 轮廓到文字图层坐标的矩阵，包含竖排 extraMatrix、glyphScale 和基线平移。
    let matrix: SceneAffine
    /// PreparedTextLayer.fonts 中的实际字体索引，用于维持上游按 style 分组的顺序。
    let fontIndex: Int
    /// 原 Unicode cluster 在输入 UTF-16 中的右开范围，用于诊断，不作为缓存身份。
    let cluster: Range<Int>
}

/// 一轮文字绘制；完整执行本轮全部 glyph 后才执行下一轮。
enum TextPaintPass: Sendable {
    /// 使用每 glyph 的 fill 路径和关联的非预乘 RGBA 色。
    case fill(PAGColor)
    /// 使用每 glyph 的 stroke 路径和关联的非预乘 RGBA 色。
    case stroke(PAGColor)
}

/// 场景安装/文本编辑时完成的文字资源；每帧只引用它，不重新整形或生成轮廓。
final class PreparedTextLayer: Sendable {
    /// 本次准备的稳定资源代数，多实例和多帧保持相同。
    let identity: TextResourceID
    /// 此资源实际使用的完整编辑样式，用于显式复用时检查失效。
    let style: PAGText
    /// 按 Text::MakeFrom 的字体/线性矩阵首次出现顺序分组后的 glyph 列表。
    let glyphs: [PreparedTextGlyph]
    /// 已选定的全部 fill/stroke 绘制轮次，颜色自身可含公开编辑的 alpha。
    let passes: [TextPaintPass]
    /// 按 PAG 源规则得到的逻辑布局，字体 bounds 不代表实际像素覆盖。
    let layout: TextLayoutResult
    /// 本次实际使用的字体及回退诊断，数组顺序与 fontIndex 一致。
    let fonts: [TextFontInfo]
    /// 整形输出中 glyph ID 为0的输入索引；按上游规则没有路径或 advance。
    let missingGlyphIndices: [Int]
    /// 完整准备的保守逻辑计费，显式复用时也要满足新调用的预算。
    let estimatedBytes: Int

    /// 保存完整准备结果；失败时调用方不构造/发布该对象。
    init(style: PAGText, glyphs: [PreparedTextGlyph], passes: [TextPaintPass], layout: TextLayoutResult,
         fonts: [TextFontInfo], missingGlyphIndices: [Int], estimatedBytes: Int) {
        identity = TextResourceID(generation: UUID())
        self.style = style
        self.glyphs = glyphs
        self.passes = passes
        self.layout = layout
        self.fonts = fonts
        self.missingGlyphIndices = missingGlyphIndices
        self.estimatedBytes = estimatedBytes
    }
}
