import CoreText
import Foundation

/// 一次后台整形的系统对象容器；不满足 Sendable，必须在同一同步准备作用域内消费。
struct SystemTextShaping {
    /// 按实际相等性去重、已换成 PAG 字号的临时字体，不能进入 PreparedTextLayer。
    let fonts: [CTFont]
    /// 与 fonts 同序的可共享诊断值。
    let fontInfo: [TextFontInfo]
    /// CoreText 视觉顺序中的 glyph，不采用其整体排版位置代替 PAG 布局。
    let glyphs: [SystemTextGlyph]
}

/// CoreText 输出的单 glyph 身份；UTF-16 索引由 TextClusters 另外验证。
struct SystemTextGlyph {
    /// SystemTextShaping.fonts 中实际字体的位置。
    let fontIndex: Int
    /// 字体内 glyph ID，零按上游 Font 规则表示无路径和 advance。
    let id: CGGlyph
    /// 对应源字符串的 UTF-16 起点，视觉 RTL 顺序中不一定递增。
    let stringIndex: Int
}

/// Cocoa 原生整形适配；沿 NativeTextShaper 的 CTLine/run 路径，不引入主 actor。
enum CoreTextShaper {
    /// 同步创建并读取系统 line/run；输入、临时数组和字体诊断均计入准备预算。
    static func shape(_ style: PAGText, budget: inout FramePlanBudget) throws -> SystemTextShaping {
        try Task.checkCancellation()
        let size = try TextLayoutSettings.finite(Float(style.fontSize))
        guard size > 0 else { throw SceneValidator.invalid("unrepresentableTextLayout") }
        try budget.reserve(count: style.text.utf16.count, stride: 256)
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let font = requestedFont(style) { attributes[NSAttributedString.Key(kCTFontAttributeName as String)] = font }
        // 主字体沿上游 descriptor 默认字号整形；PAG 字号稍后作用到实际 fallback 字体的指标和轮廓。
        let attributed = NSAttributedString(string: style.text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        try Task.checkCancellation()
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        var fonts: [CTFont] = []
        var info: [TextFontInfo] = []
        var result: [SystemTextGlyph] = []
        for run in runs {
            try Task.checkCancellation()
            let values = CTRunGetAttributes(run) as NSDictionary
            guard let value = values[kCTFontAttributeName], CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() else {
                throw SceneValidator.invalid("missingShapedFont")
            }
            // 上面的 CoreFoundation 类型检查先证明转换安全，不把任意属性对象当成 CTFont。
            let actual = CTFontCreateCopyWithAttributes(value as! CTFont, CGFloat(size), nil, nil)
            if CTFontGetSymbolicTraits(actual).contains(.traitColorGlyphs) {
                throw PAGError.unsupportedFeature("textColorGlyphs")
            }
            let format = CTFontCopyAttribute(actual, kCTFontFormatAttribute) as? NSNumber
            guard let format, format.uint32Value != CTFontFormat.unrecognized.rawValue,
                  format.uint32Value != CTFontFormat.bitmap.rawValue else {
                throw PAGError.unsupportedFeature("textBitmapFont")
            }
            let fontIndex: Int
            if let index = fonts.firstIndex(where: { CFEqual($0, actual) }) { fontIndex = index }
            else {
                try budget.reserve(stride: 1024)
                let family = CTFontCopyFamilyName(actual) as String
                let fontStyle = CTFontCopyName(actual, kCTFontStyleNameKey) as String? ?? ""
                let name = CTFontCopyPostScriptName(actual) as String
                try budget.reserve(count: family.utf8.count + fontStyle.utf8.count + name.utf8.count, stride: 2)
                fontIndex = fonts.count
                fonts.append(actual)
                info.append(TextFontInfo(family: family, style: fontStyle, postScriptName: name,
                                         substitutesRequest: (!style.fontFamily.isEmpty && family != style.fontFamily)
                                            || (!style.fontStyle.isEmpty && fontStyle != style.fontStyle)))
            }
            let count = CTRunGetGlyphCount(run)
            try budget.reserve(count: count, stride: 160)
            var ids = [CGGlyph](repeating: 0, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &ids)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            for index in 0..<count {
                try Task.checkCancellation()
                result.append(SystemTextGlyph(fontIndex: fontIndex, id: ids[index], stringIndex: indices[index]))
            }
        }
        try Task.checkCancellation()
        return SystemTextShaping(fonts: fonts, fontInfo: info, glyphs: result)
    }

    /// 仅接受匹配家族的请求字体；旧 FontManager 的首空格拆分仍失败时交给系统默认级联。
    private static func requestedFont(_ style: PAGText) -> CTFont? {
        if let exact = font(family: style.fontFamily, style: style.fontStyle) { return exact }
        if let space = style.fontFamily.firstIndex(of: " ") {
            let family = String(style.fontFamily[..<space])
            let suffix = String(style.fontFamily[style.fontFamily.index(after: space)...])
            return font(family: family, style: suffix)
        }
        return nil
    }

    /// 按固定 CGTypeface 的 family/style descriptor 创建默认字号字体，不暗中接受家族失配。
    private static func font(family: String, style: String) -> CTFont? {
        guard !family.isEmpty else { return nil }
        var attributes: [String: Any] = [kCTFontFamilyNameAttribute as String: family]
        if !style.isEmpty { attributes[kCTFontStyleNameAttribute as String] = style }
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, 0, nil)
        return CTFontCopyFamilyName(font) as String == family ? font : nil
    }
}
