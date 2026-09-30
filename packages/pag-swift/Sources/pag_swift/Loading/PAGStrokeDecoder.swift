/// Stroke.cpp与Dashes.cpp的完整普通描边读取；字段进入共享求值和Metal绘制，不支持其他形状效果。
extension PAGSceneDecoder {
    /// 按九项源码配置消费普通描边；不支持的枚举、尾随、预算与取消都不返回半份属性。
    mutating func readStroke(reader: inout PAGByteReader) throws -> SourceStroke {
        try Task.checkCancellation()
        try budget.reserve(512)
        let flags = try PropertyFlags.read([.flag, .flag, .flag, .flag,
                                           .property, .property, .property, .property, .flag], from: &reader)
        try StaticAttributes.requireDefault(flags[0].exists, name: "strokeBlendMode", from: &reader)
        let order: ShapeCompositeOrder = try strokeEnum(flags[1].exists, defaultValue: .belowPrevious,
                                                        name: "strokeCompositeOrder", reader: &reader)
        let cap: SourceLineCap = try strokeEnum(flags[2].exists, defaultValue: .butt, name: "strokeLineCap", reader: &reader)
        let join: SourceLineJoin = try strokeEnum(flags[3].exists, defaultValue: .miter, name: "strokeLineJoin", reader: &reader)
        let miter = try readScalarProperty(flags[4], defaultValue: 4, reader: &reader)
        let color = try readColorProperty(flags[5], defaultValue: SceneColor(red: 255, green: 255, blue: 255), reader: &reader)
        let opacity = try readOpacityProperty(flags[6], reader: &reader)
        let width = try readScalarProperty(flags[7], defaultValue: 2, reader: &reader)
        let dashes = try flags[8].exists ? readStrokeDashes(reader: &reader) : nil
        try StaticAttributes.requireEnd(of: reader)
        try Task.checkCancellation()
        return SourceStroke(compositeOrder: order, cap: cap, join: join, miterLimit: miter,
                            color: color, opacity: opacity, width: width, dashes: dashes)
    }

    /// Custom进入时字节对齐，三位计数允许1...8；全部flags先于所有属性内容，不采用writer的六项截断。
    mutating func readStrokeDashes(reader: inout PAGByteReader) throws -> SourceDashes {
        reader.alignToByte()
        let count = Int(try reader.readUnsignedBits(count: 3)) + 1
        try budget.reserve(count: count + 1, stride: 128)
        let flags = try PropertyFlags.read(Array(repeating: .property, count: count + 1), from: &reader)
        let offset = try readScalarProperty(flags[0], defaultValue: 0, reader: &reader)
        var intervals: [SourceProperty<Double>] = []
        for index in 1...count {
            try Task.checkCancellation()
            intervals.append(try readScalarProperty(flags[index], defaultValue: 10, reader: &reader))
        }
        return try SourceDashes(offset: offset, intervals: intervals)
    }

    /// Value只有存在位，未知UInt8值明确失败，不能按TGFX默认switch悄悄退回另一种端点或接角。
    func strokeEnum<Value: RawRepresentable>(_ exists: Bool, defaultValue: Value, name: String,
                                                     reader: inout PAGByteReader) throws -> Value where Value.RawValue == UInt8 {
        guard exists else { return defaultValue }
        guard let value = Value(rawValue: try reader.readUInt8()) else { throw PAGError.unsupportedFeature(name) }
        return value
    }
}
