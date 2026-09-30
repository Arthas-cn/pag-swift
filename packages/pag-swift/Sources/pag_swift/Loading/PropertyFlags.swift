/// 单项属性的已读取标记；空间切线位只在 SpatialProperty 且动画存在时编码。
struct PropertyFlags {
    /// 属性有值载荷；BitFlag 则直接表示布尔值。
    let exists: Bool
    /// 存在关键帧列表而不是单个常量值。
    let isAnimated: Bool
    /// 动画额外含空间 in/out 切线列表，不是时间缓动。
    let hasSpatial: Bool

    /// 按 AttributeHelper::ReadAttributeFlag 先读整个配置列表，再统一字节对齐。
    static func read(_ encodings: [AttributeEncoding], from reader: inout PAGByteReader) throws -> [PropertyFlags] {
        var result: [PropertyFlags] = []
        for encoding in encodings {
            if case .fixed = encoding {
                result.append(PropertyFlags(exists: true, isAnimated: false, hasSpatial: false))
                continue
            }
            let exists = try reader.readUnsignedBits(count: 1) != 0
            if case .flag = encoding {
                result.append(PropertyFlags(exists: exists, isAnimated: false, hasSpatial: false))
                continue
            }
            let animated = try exists && reader.readUnsignedBits(count: 1) != 0
            var spatial = false
            if animated, case .spatialProperty = encoding { spatial = try reader.readUnsignedBits(count: 1) != 0 }
            result.append(PropertyFlags(exists: exists, isAnimated: animated, hasSpatial: spatial))
        }
        reader.alignToByte()
        return result
    }
}
