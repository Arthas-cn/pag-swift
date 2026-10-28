/// tag29/65的内部字段读取；图层仅允许已接通的静态局部滤镜子范围公开加载。
extension PAGSceneDecoder {
    /// 按上游BlockConfig完整消费静态投影字段；动画样式显式失败，不发布错误常量。
    mutating func readDropShadow(code: UInt16, reader: inout PAGByteReader) throws -> SourceDropShadow {
        guard code == 29 || code == 65 else { throw SceneValidator.invalid("invalidDropShadowTag") }
        let count = code == 65 ? 7 : 6
        let flags = try PropertyFlags.read(Array(repeating: .property, count: count), from: &reader)
        // 当前真实样式全是静态轨道；动画布局没有在此子段验证，不能错位读取为常量。
        guard !flags.contains(where: \.isAnimated) else {
            throw PAGError.unsupportedFeature("animatedDropShadow")
        }
        let blendMode = try flags[0].exists ? reader.readUInt8() : 0
        let color = try flags[1].exists ? StaticAttributes.color(from: &reader) : SceneColor(red: 0, green: 0, blue: 0)
        let opacity = try flags[2].exists ? reader.readUInt8() : 191
        let angle = try flags[3].exists ? StaticAttributes.scalar(from: &reader) : 120
        let distance = try flags[4].exists ? StaticAttributes.scalar(from: &reader) : 5
        let size = try flags[5].exists ? StaticAttributes.scalar(from: &reader) : 5
        let spread = try code == 65 && flags[6].exists ? StaticAttributes.scalar(from: &reader) : 0
        try StaticAttributes.requireEnd(of: reader)
        try budget.reserve(128)
        return SourceDropShadow(blendMode: blendMode, color: color, opacity: opacity,
                                angle: angle, distance: distance, size: size, spread: spread)
    }
}
