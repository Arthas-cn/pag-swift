/// 既有形状元素的完整属性读取；只消费已取证字段，轨道统一交给共同帧准备和显示核心。
extension PAGSceneDecoder {
    /// 依据ShapeGroup.cpp::ShapeGroupTag读取变换前缀，成功后游标停在Custom子标签之前。
    mutating func readShapeGroupProperties(reader: inout PAGByteReader) throws
        -> (transform: SourceShapeTransformProperties, hasElements: Bool) {
        try Task.checkCancellation()
        try budget.reserve(512)
        // Spatial动画多一个hasSpatial位；必须先完整读flags再消费属性，不能使用旧静态配置。
        let flags = try PropertyFlags.read([.flag, .spatialProperty, .spatialProperty, .property,
            .property, .property, .property, .property, .flag], from: &reader)
        try StaticAttributes.requireDefault(flags[0].exists, name: "shapeBlendMode", from: &reader)
        let anchor = try readPointProperty(flags[1], defaultValue: .zero, spatial: true, reader: &reader)
        let position = try readPointProperty(flags[2], defaultValue: .zero, spatial: true, reader: &reader)
        let scale = try readPointProperty(flags[3], defaultValue: .one, spatial: false, reader: &reader)
        let skew = try readScalarProperty(flags[4], defaultValue: 0, reader: &reader)
        let axis = try readScalarProperty(flags[5], defaultValue: 0, reader: &reader)
        let rotation = try readScalarProperty(flags[6], defaultValue: 0, reader: &reader)
        let opacity = try readOpacityProperty(flags[7], reader: &reader)
        try Task.checkCancellation()
        return (SourceShapeTransformProperties(anchor: anchor, position: position, scale: scale,
            skew: skew, skewAxis: axis, rotation: rotation, opacity: opacity), flags[8].exists)
    }

    /// 依据Rectangle.cpp::RectangleTag消费完整载荷；未知尾随、预算不足或取消均失败。
    mutating func readRectangleProperties(reader: inout PAGByteReader) throws -> SourceRectangle {
        try Task.checkCancellation()
        try budget.reserve(256)
        let flags = try PropertyFlags.read([.flag, .property, .spatialProperty, .property], from: &reader)
        let size = try readPointProperty(flags[1], defaultValue: ScenePoint(x: 100, y: 100),
                                        spatial: false, reader: &reader)
        let position = try readPointProperty(flags[2], defaultValue: .zero, spatial: true, reader: &reader)
        let roundness = try readScalarProperty(flags[3], defaultValue: 0, reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        try Task.checkCancellation()
        return SourceRectangle(reversed: flags[0].exists, size: size, position: position, roundness: roundness)
    }

    /// 依据Fill.cpp::FillTag读取完整颜色/opacity轨道；非Normal、Below、NonZero值明确拒绝。
    mutating func readFillProperties(reader: inout PAGByteReader) throws -> SourceFill {
        try Task.checkCancellation()
        try budget.reserve(128)
        let flags = try PropertyFlags.read([.flag, .flag, .flag, .property, .property], from: &reader)
        try StaticAttributes.requireDefault(flags[0].exists, name: "fillBlendMode", from: &reader)
        try StaticAttributes.requireDefault(flags[1].exists, name: "fillCompositeOrder", from: &reader)
        try StaticAttributes.requireDefault(flags[2].exists, name: "fillRule", from: &reader)
        let color = try readColorProperty(flags[3], defaultValue: .defaultFill, reader: &reader)
        let opacity = try readOpacityProperty(flags[4], reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        try Task.checkCancellation()
        return SourceFill(color: color, opacity: opacity)
    }
}
