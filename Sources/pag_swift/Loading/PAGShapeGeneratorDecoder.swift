/// 有源码字段证据且已通过显示闭包的Ellipse/PolyStar读取器，不承担源帧求值或路径生成。
extension PAGSceneDecoder {
    /// 依据Ellipse.cpp::EllipseTag完整读取尺寸与Spatial位置；截断、尾随、预算或取消均失败。
    mutating func readEllipse(reader: inout PAGByteReader) throws -> SourceEllipse {
        try Task.checkCancellation()
        try budget.reserve(192)
        let flags = try PropertyFlags.read([.flag, .property, .spatialProperty], from: &reader)
        let size = try readPointProperty(flags[1], defaultValue: ScenePoint(x: 100, y: 100),
                                        spatial: false, reader: &reader)
        let position = try readPointProperty(flags[2], defaultValue: .zero, spatial: true, reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        try Task.checkCancellation()
        return SourceEllipse(reversed: flags[0].exists, size: size, position: position)
    }

    /// 依据PolyStar.cpp::PolyStarTag按源顺序读齐七条轨道；未知kind拒绝，不返回部分属性。
    mutating func readPolyStar(reader: inout PAGByteReader) throws -> SourcePolyStar {
        try Task.checkCancellation()
        try budget.reserve(512)
        let flags = try PropertyFlags.read([.flag, .flag, .property, .spatialProperty,
            .property, .property, .property, .property, .property], from: &reader)
        let rawKind = try flags[1].exists ? reader.readUInt8() : 0
        // 上游renderer的else会把未知值当Polygon，但只有0/1有枚举证据，不能据此宽容降级。
        guard let kind = SourcePolyStarKind(rawValue: rawKind) else {
            throw PAGError.unsupportedFeature("polyStarKind")
        }
        let points = try readScalarProperty(flags[2], defaultValue: 5, reader: &reader)
        let position = try readPointProperty(flags[3], defaultValue: .zero, spatial: true, reader: &reader)
        let rotation = try readScalarProperty(flags[4], defaultValue: 0, reader: &reader)
        let innerRadius = try readScalarProperty(flags[5], defaultValue: 50, reader: &reader)
        let outerRadius = try readScalarProperty(flags[6], defaultValue: 100, reader: &reader)
        let innerRoundness = try readScalarProperty(flags[7], defaultValue: 0, reader: &reader)
        let outerRoundness = try readScalarProperty(flags[8], defaultValue: 0, reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        try Task.checkCancellation()
        return SourcePolyStar(kind: kind, reversed: flags[0].exists, points: points, position: position,
            rotation: rotation, innerRadius: innerRadius, outerRadius: outerRadius,
            innerRoundness: innerRoundness, outerRoundness: outerRoundness)
    }
}
