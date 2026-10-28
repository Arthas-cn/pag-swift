/// 静态文本的完整样式/排版读取，保留非公开编辑字段，不在解码时排版。
extension PAGSceneDecoder {
    /// TextSource.cpp 外层是单个 DiscreteProperty；只有静态分支在此阶段接受。
    func readText(code: UInt16, reader: inout PAGByteReader) throws -> SourceText {
        let sourceFlags = try StaticAttributes.flags([.property], from: &reader)
        guard sourceFlags[0] else { return try defaultText(code: code) }
        // DataTypes.cpp::TextDocumentBlockCore 重新开始一整组 flags，并在之后读取载荷。
        let hasBackground = code >= 64
        let hasDirection = code >= 68
        let count = 19 + (hasBackground ? 2 : 0) + (hasDirection ? 1 : 0)
        let f = try StaticAttributes.flags(Array(repeating: .flag, count: count), from: &reader)
        let baseline = try f[6] ? StaticAttributes.scalar(from: &reader) : 0
        let firstBaseline = try f[7] ? StaticAttributes.scalar(from: &reader) : 0
        let boxPosition = try f[8] ? StaticAttributes.point(from: &reader) : .zero
        let boxSize = try f[9] ? StaticAttributes.point(from: &reader) : .zero
        let fill = try f[10] ? StaticAttributes.color(from: &reader) : SceneColor(red: 0, green: 0, blue: 0)
        let fontSize = try f[11] ? StaticAttributes.scalar(from: &reader) : 24
        let stroke = try f[12] ? StaticAttributes.color(from: &reader) : SceneColor(red: 0, green: 0, blue: 0)
        let strokeWidth = try f[13] ? StaticAttributes.scalar(from: &reader) : 1
        let text = try f[14] ? reader.readUTF8String() : ""
        let justification = try f[15] ? reader.readUInt8() : 0
        let leading = try f[16] ? StaticAttributes.scalar(from: &reader) : 0
        let tracking = try f[17] ? StaticAttributes.scalar(from: &reader) : 0
        let background = try hasBackground && f[18] ? StaticAttributes.color(from: &reader) : SceneColor(red: 255, green: 255, blue: 255)
        let backgroundAlpha: UInt8 = try hasBackground ? (f[19] ? reader.readUInt8() : 255) : 0
        // V3 内层缺省方向为 Vertical；外层属性整体缺失的缺省值却是 Horizontal。
        let direction: UInt8 = try hasDirection ? (f[20] ? reader.readUInt8() : 2) : 0
        var font = SourceFont(family: "", style: "")
        if f[count - 1] {
            let id = try reader.readEncodedUInt32()
            guard let entry = resources.fonts[id] else { throw SceneValidator.invalid("missingFontReference") }
            font = entry
        }
        guard fontSize > 0, strokeWidth >= 0, justification <= 6, direction <= 2 else {
            throw SceneValidator.invalid("invalidTextStyle")
        }
        let style = try PAGText(text: text, fontSize: fontSize, fontFamily: font.family, fontStyle: font.style,
                                fillColor: f[0] ? publicColor(fill) : nil, strokeColor: f[1] ? publicColor(stroke) : nil,
                                strokeWidth: strokeWidth, leading: leading, tracking: tracking)
        return SourceText(style: style, baselineShift: baseline, firstBaseline: firstBaseline, isBoxText: f[2],
                          boxPosition: boxPosition, boxSize: boxSize, fauxBold: f[3], fauxItalic: f[4],
                          strokeOverFill: f[5], justification: justification, backgroundColor: background,
                          backgroundAlpha: backgroundAlpha, direction: direction)
    }

    /// TextSourceTag 的整个属性缺失时使用 TextDocument 初始化值及版本触发默认值。
    private func defaultText(code: UInt16) throws -> SourceText {
        let style = try PAGText(text: "", fontSize: 24, fillColor: PAGColor(red: 0, green: 0, blue: 0), strokeWidth: 1)
        return SourceText(style: style, baselineShift: 0, firstBaseline: 0, isBoxText: false,
                          boxPosition: .zero, boxSize: .zero, fauxBold: false, fauxItalic: false,
                          strokeOverFill: true, justification: 0, backgroundColor: SceneColor(red: 255, green: 255, blue: 255),
                          backgroundAlpha: code == 64 ? 255 : 0, direction: code == 68 ? 1 : 0)
    }

    /// 原始 RGB 字节转换到公开的非预乘 0...1 色值，不添加不存在的 alpha 字段。
    private func publicColor(_ color: SceneColor) throws -> PAGColor {
        try PAGColor(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255)
    }
}
