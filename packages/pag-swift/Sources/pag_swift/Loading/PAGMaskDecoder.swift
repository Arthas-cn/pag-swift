/// MaskTag.cpp字段的完整读取；正式层保留14/84源列表，未实现的画面模式在求值时失败。
extension PAGSceneDecoder {
    /// 完整读取14/84的源轨道；未知版本/模式、损坏、非有限、预算和取消均直接失败。
    mutating func readMask(code: UInt16, reader: inout PAGByteReader) throws -> SourceMask {
        try Task.checkCancellation()
        guard code == 14 || code == 84 else { throw PAGError.unsupportedFeature("maskTag:\(code)") }
        try budget.reserve(512)
        var encodings: [AttributeEncoding] = [.fixed, .flag, .flag, .property]
        if code == 84 { encodings.append(.spatialProperty) }
        encodings += [.property, .property]
        let flags = try PropertyFlags.read(encodings, from: &reader)
        let id = try reader.readEncodedUInt32()
        let rawMode = try flags[2].exists ? reader.readUInt8() : 1
        guard let mode = SourceMaskMode(rawValue: rawMode) else { throw PAGError.unsupportedFeature("maskMode") }
        let path = try readPathProperty(flags[3], reader: &reader)
        // LayerCache以指针是否存在选分支；84的缺省零点仍必须保存，不能与14合并。
        let feather = try code == 84 ? readPointProperty(flags[4], defaultValue: .zero, spatial: true, reader: &reader) : nil
        let opacityIndex = code == 84 ? 5 : 4
        let opacity = try readOpacityProperty(flags[opacityIndex], reader: &reader)
        let expansion = try readScalarProperty(flags[opacityIndex + 1], defaultValue: 0, reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        try Task.checkCancellation()
        return SourceMask(id: id, isInverted: flags[1].exists, mode: mode, path: path,
                          feather: feather, opacity: opacity, expansion: expansion)
    }
}
