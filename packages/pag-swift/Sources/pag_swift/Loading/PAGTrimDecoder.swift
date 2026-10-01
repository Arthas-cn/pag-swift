/// TrimPaths正式分发使用的字段读取；只保留源轨道，不生成显示几何。
extension PAGSceneDecoder {
    /// 按TrimPaths.cpp::TrimPathsTag读取三条标量轨道和模式；截断、尾随、非有限、预算或取消均失败。
    mutating func readTrimPaths(reader: inout PAGByteReader) throws -> SourceTrimPaths {
        try Task.checkCancellation()
        try budget.reserve(256)
        let flags = try PropertyFlags.read([.property, .property, .property, .flag], from: &reader)
        let start = try readScalarProperty(flags[0], defaultValue: 0, reader: &reader)
        // 上游为兼容旧文件明确保留100；不能按Percent注释把它修成1或在这里归一化。
        let end = try readScalarProperty(flags[1], defaultValue: 100, reader: &reader)
        let offset = try readScalarProperty(flags[2], defaultValue: 0, reader: &reader)
        let rawMode = try flags[3].exists ? reader.readUInt8() : 0
        // 源renderer的else会接纳所有非0值，但只有0/1有枚举证据，本库不据此猜测其他模式。
        guard let mode = SourceTrimMode(rawValue: rawMode) else {
            throw PAGError.unsupportedFeature("trimPathsMode")
        }
        try StaticAttributes.requireEnd(of: reader)
        try Task.checkCancellation()
        return SourceTrimPaths(start: start, end: end, offset: offset, mode: mode)
    }
}
