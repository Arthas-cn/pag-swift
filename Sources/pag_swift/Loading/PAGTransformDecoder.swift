/// Transform2D 轨道读取，保留组合与分离位置的源码选择规则。
extension PAGSceneDecoder {
    /// 按 Transform2DTag 的七项顺序读取全部 flags 后才读常量/关键帧载荷。
    mutating func readTransform(reader: inout PAGByteReader) throws -> SourceTransformProperties {
        let flags = try PropertyFlags.read([.spatialProperty, .spatialProperty, .property, .property,
                                            .property, .property, .property], from: &reader)
        let anchor = try readPointProperty(flags[0], defaultValue: .zero, spatial: true, reader: &reader)
        let position = try readPointProperty(flags[1], defaultValue: .zero, spatial: true, reader: &reader)
        let x = try readScalarProperty(flags[2], defaultValue: 0, reader: &reader)
        let y = try readScalarProperty(flags[3], defaultValue: 0, reader: &reader)
        let scale = try readPointProperty(flags[4], defaultValue: .one, spatial: false, reader: &reader)
        let rotation = try readScalarProperty(flags[5], defaultValue: 0, reader: &reader)
        let opacity = try readOpacityProperty(flags[6], reader: &reader)
        let combined = position.isAnimated || position.initialValue != .zero
        let separate = x.isAnimated || y.isAnimated || x.initialValue != 0 || y.initialValue != 0
        // 动画即使在第零帧为零也优先使用组合位置；不能随采样时刻反复切换坐标表达。
        let selected: SourcePosition = combined || !separate ? .combined(position) : .separated(x: x, y: y)
        return SourceTransformProperties(anchor: anchor, position: selected, scale: scale, rotation: rotation, opacity: opacity)
    }
}
