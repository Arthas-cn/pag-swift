/// 形状源数据解码，与图层/合成解析共用预算；动画路径只保留轨道，不在读取时求值。
extension PAGSceneDecoder {
    /// 解码已支持的形状 tag；组递归超过内部 64 层限制时在下降前失败。
    mutating func readShape(code: UInt16, reader: inout PAGByteReader, depth: Int) throws -> SourceShape {
        try Task.checkCancellation()
        try budget.reserve(256)
        switch code {
        case 15:
            guard depth <= 64 else { throw PAGError.resourceLimitExceeded("maximumShapeDepth") }
            return try readShapeGroup(reader: &reader, depth: depth)
        case 16:
            return try readRectangle(reader: &reader)
        case 17:
            // Ellipse.cpp字段与顶部Conic生成已通过真实drawable门禁，保持未排序尺寸语义。
            return try .ellipse(readEllipse(reader: &reader))
        case 18:
            // PolyStar.cpp字段与源Float生成已闭包；未知kind仍由读取器明确拒绝。
            return try .polyStar(readPolyStar(reader: &reader))
        case 19:
            return try .path(readShapePath(reader: &reader))
        case 20:
            return try readFill(reader: &reader)
        case 21:
            // file.h::TagCode::Stroke与codec/tags/shapes/Stroke.cpp给出字段布局，已通过完整描边显示门禁。
            return try .stroke(readStroke(reader: &reader))
        case 22:
            // Gradient.cpp::GradientFillTag字段、颜色编译与直接drawable已闭包；未知布局仍由读取器拒绝。
            return try .gradientFill(readGradientFill(reader: &reader))
        case 23:
            // Gradient.cpp::GradientStrokeTag独立字段次序已经验证，几何与普通Stroke共用已验收的样式核心。
            return try .gradientStroke(readGradientStroke(reader: &reader))
        case 25:
            // TrimPaths.cpp字段、两阶段路径作用域与直接drawable已闭包，未知模式仍明确拒绝。
            return try .trimPaths(readTrimPaths(reader: &reader))
        default:
            throw PAGError.unsupportedFeature("shapeTag:\(code)")
        }
    }

    /// 依据 shapes/ShapeGroup.cpp，全部 flags 后才读取变换和 Custom 子标签列表。
    private mutating func readShapeGroup(reader: inout PAGByteReader, depth: Int) throws -> SourceShape {
        let properties = try readShapeGroupProperties(reader: &reader)
        var elements: [SourceShape] = []
        if properties.hasElements {
            while var block = try nextBlock(from: &reader) {
                elements.append(try readShape(code: block.code, reader: &block.reader, depth: depth + 1))
                try StaticAttributes.requireEnd(of: block.reader)
            }
        }
        return .group(properties.transform, elements)
    }

    /// 依据 shapes/Rectangle.cpp，尺寸/中心/圆角缺省为 100×100、零、零。
    private mutating func readRectangle(reader: inout PAGByteReader) throws -> SourceShape {
        let properties = try readRectangleProperties(reader: &reader)
        return .rectangle(properties)
    }

    /// 依据 shapes/Fill.cpp，缺省色是 Red，不能因为载荷只有 flags 就省掉填充。
    private mutating func readFill(reader: inout PAGByteReader) throws -> SourceShape {
        let properties = try readFillProperties(reader: &reader)
        return .fill(properties)
    }
}
