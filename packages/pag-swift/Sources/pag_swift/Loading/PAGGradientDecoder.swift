/// Gradient.cpp的内部字段读取；正式tag22/23须等待共同绘制闭包，不以字段成功提前开放。
extension PAGSceneDecoder {
    /// 按GradientFillTag的八项配置完整消费；只支持Normal/NonZero及已列出的布局枚举。
    mutating func readGradientFill(reader: inout PAGByteReader) throws -> SourceGradientFill {
        try Task.checkCancellation()
        try budget.reserve(512)
        let flags = try PropertyFlags.read([.flag, .flag, .flag, .flag,
                                           .spatialProperty, .spatialProperty, .property, .property], from: &reader)
        try StaticAttributes.requireDefault(flags[0].exists, name: "gradientBlendMode", from: &reader)
        let order: ShapeCompositeOrder = try strokeEnum(flags[1].exists, defaultValue: .belowPrevious,
                                                        name: "gradientCompositeOrder", reader: &reader)
        try StaticAttributes.requireDefault(flags[2].exists, name: "gradientFillRule", from: &reader)
        let gradient = try readGradient(flags: flags, startIndex: 3, reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        try Task.checkCancellation()
        return SourceGradientFill(compositeOrder: order, gradient: gradient)
    }

    /// GradientStroke的width/cap/join位于共同渐变字段之后，不能复用普通Stroke的字段顺序。
    mutating func readGradientStroke(reader: inout PAGByteReader) throws -> SourceGradientStroke {
        try Task.checkCancellation()
        try budget.reserve(768)
        let flags = try PropertyFlags.read([.flag, .flag, .flag, .spatialProperty, .spatialProperty,
            .property, .property, .property, .flag, .flag, .property, .flag], from: &reader)
        try StaticAttributes.requireDefault(flags[0].exists, name: "gradientBlendMode", from: &reader)
        let order: ShapeCompositeOrder = try strokeEnum(flags[1].exists, defaultValue: .belowPrevious,
                                                        name: "gradientCompositeOrder", reader: &reader)
        let gradient = try readGradient(flags: flags, startIndex: 2, reader: &reader)
        let width = try readScalarProperty(flags[7], defaultValue: 2, reader: &reader)
        let cap: SourceLineCap = try strokeEnum(flags[8].exists, defaultValue: .butt, name: "strokeLineCap", reader: &reader)
        let join: SourceLineJoin = try strokeEnum(flags[9].exists, defaultValue: .miter, name: "strokeLineJoin", reader: &reader)
        let miter = try readScalarProperty(flags[10], defaultValue: 4, reader: &reader)
        let dashes = try flags[11].exists ? readStrokeDashes(reader: &reader) : nil
        try StaticAttributes.requireEnd(of: reader)
        try Task.checkCancellation()
        return SourceGradientStroke(compositeOrder: order, gradient: gradient, cap: cap,
                                    join: join, miterLimit: miter, width: width, dashes: dashes)
    }

    /// AddGradientCommonTags的五项共享字段；调用者传入已完整读取的flags及共同字段起点。
    private mutating func readGradient(flags: [PropertyFlags], startIndex: Int,
                                       reader: inout PAGByteReader) throws -> SourceGradient {
        let kind: SourceGradientKind = try strokeEnum(flags[startIndex].exists, defaultValue: .linear,
                                                      name: "gradientType", reader: &reader)
        let start = try readPointProperty(flags[startIndex + 1], defaultValue: .zero, spatial: true, reader: &reader)
        let end = try readPointProperty(flags[startIndex + 2], defaultValue: ScenePoint(x: 100, y: 0),
                                       spatial: true, reader: &reader)
        let colors = try readGradientProperty(flags[startIndex + 3], reader: &reader)
        let opacity = try readOpacityProperty(flags[startIndex + 4], reader: &reader)
        return SourceGradient(kind: kind, start: start, end: end, colors: colors, opacity: opacity)
    }
}
