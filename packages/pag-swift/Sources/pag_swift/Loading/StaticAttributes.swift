/// 已有源码证据的属性 flag 类别；具体解码器决定是否支持该属性的动画载荷。
enum AttributeEncoding {
    /// BitFlag、Value 或 Custom：只读一个存在位。
    case flag
    /// 普通 Property：存在时再读动画位，没有空间切线标志。
    case property
    /// 空间 Property：有动画时还包含是否编码空间切线的一位。
    case spatialProperty
    /// FixedValue：没有存在位，总是有载荷。
    case fixed
}

/// 静态属性和基础值读取；配置顺序由各个上游 Tag 函数确定。
enum StaticAttributes {
    /// 先读取整块 flags 再对齐；Property 的动画位为真时抛 unsupportedFeature。
    static func flags(_ encodings: [AttributeEncoding], from reader: inout PAGByteReader) throws -> [Bool] {
        let flags = try PropertyFlags.read(encodings, from: &reader)
        guard !flags.contains(where: \.isAnimated) else { throw PAGError.unsupportedFeature("animatedProperty") }
        return flags.map(\.exists)
    }

    /// 读取静态 Float32 并保留其精度；非有限属性不能进入场景或 GPU。
    static func scalar(from reader: inout PAGByteReader) throws -> Double {
        let offset = reader.position
        let value = Double(try reader.readFloat32())
        guard value.isFinite else { throw PAGError.invalidFile(reason: "nonfiniteScalar", offset: offset) }
        return value
    }

    /// DataTypes.cpp::ReadPoint 依次读取两个 Float32，不是位打包坐标列表。
    static func point(from reader: inout PAGByteReader) throws -> ScenePoint {
        try ScenePoint(x: scalar(from: &reader), y: scalar(from: &reader))
    }

    /// DataTypes.cpp::ReadColor 的三个原始 RGB 通道；没有第四个 alpha 字节。
    static func color(from reader: inout PAGByteReader) throws -> SceneColor {
        try SceneColor(red: reader.readUInt8(), green: reader.readUInt8(), blue: reader.readUInt8())
    }

    /// ReadTime/WriteTime 以无符号编码保存有符号 Frame 的完整位模式，保留负起点。
    static func frame(from reader: inout PAGByteReader) throws -> Int64 {
        Int64(bitPattern: try reader.readEncodedUInt64())
    }

    /// 读取只有默认枚举值受支持的字段；非默认值明确失败，不能静默丢弃。
    static func requireDefault(_ exists: Bool, name: String, from reader: inout PAGByteReader) throws {
        if exists, try reader.readUInt8() != 0 { throw PAGError.unsupportedFeature(name) }
    }

    /// 验证支持的块已完整消费，拒绝误解释字段后遗留的载荷。
    static func requireEnd(of reader: PAGByteReader) throws {
        guard reader.remainingByteCount == 0 else {
            throw PAGError.invalidFile(reason: "unconsumedTagPayload", offset: reader.position)
        }
    }

}
