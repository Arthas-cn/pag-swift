@testable import pag_swift

/// 逐属性静态范围测试的纯语义夹具；所有动画端值相同，不伪造PAG字节。
enum ShapeRangeFixtures {
    /// 十类已支持Shape的属性数；两类描边包含offset及全部八条dash。
    static let cases: [(String, Int)] = [
        ("group", 7), ("rectangle", 3), ("ellipse", 2), ("polyStar", 7), ("path", 1),
        ("fill", 2), ("stroke", 13), ("gradientFill", 4), ("gradientStroke", 15), ("trim", 3)
    ].flatMap { family, count in (0..<count).map { (family, $0) } }

    /// 只把指定属性变成20..<40的同值Linear；其他属性为常量。
    static func property<Value: Sendable>(_ value: Value, index: Int, selected: Int,
                                          start: Int64 = 20, end: Int64 = 40) throws -> SourceProperty<Value> {
        guard index == selected else { return .init(constant: value) }
        return try SourceProperty(keyframes: [SourceKeyframe(startFrame: start, endFrame: end,
            startValue: value, endValue: value, easing: .linear, spatialCurve: nil)])
    }

    /// 按源字段角色逐一注入动画；selected为-1时得到同结构全常量，避免用绘制优化影响期望。
    static func element(_ family: String, selected: Int) throws -> SourceShape {
        switch family {
        case "group":
            return try .group(ShapePropertyFixtures.group(
                anchor: property(.zero, index: 0, selected: selected),
                position: property(.zero, index: 1, selected: selected),
                scale: property(.one, index: 2, selected: selected),
                skew: property(0, index: 3, selected: selected),
                skewAxis: property(0, index: 4, selected: selected),
                rotation: property(0, index: 5, selected: selected),
                opacity: property(0, index: 6, selected: selected)), [])
        case "rectangle":
            return try ShapePropertyFixtures.rectangle(
                size: property(.zero, index: 1, selected: selected),
                position: property(.zero, index: 0, selected: selected),
                roundness: property(0, index: 2, selected: selected))
        case "ellipse":
            return try .ellipse(ShapeGeneratorFixtures.ellipse(
                size: property(.zero, index: 1, selected: selected),
                position: property(.zero, index: 0, selected: selected)))
        case "polyStar":
            return try .polyStar(ShapeGeneratorFixtures.polyStar(kind: .polygon,
                points: property(0, index: 0, selected: selected),
                position: property(.zero, index: 1, selected: selected),
                rotation: property(0, index: 2, selected: selected),
                innerRadius: property(0, index: 3, selected: selected),
                outerRadius: property(0, index: 4, selected: selected),
                innerRoundness: property(0, index: 5, selected: selected),
                outerRoundness: property(0, index: 6, selected: selected)))
        case "path":
            return try .path(property(SourcePath(verbs: [], points: []), index: 0, selected: selected))
        case "fill":
            return try ShapePropertyFixtures.fill(color: property(.defaultFill, index: 0, selected: selected),
                opacity: property(0, index: 1, selected: selected))
        case "stroke":
            return try .stroke(SourceStroke(compositeOrder: .abovePrevious, cap: .butt, join: .miter,
                miterLimit: property(0, index: 0, selected: selected),
                color: property(.defaultFill, index: 1, selected: selected),
                opacity: property(0, index: 2, selected: selected),
                width: property(0, index: 3, selected: selected), dashes: dashes(firstIndex: 4, selected: selected)))
        case "gradientFill":
            return try .gradientFill(.init(compositeOrder: .belowPrevious, gradient: gradient(firstIndex: 0, selected: selected)))
        case "gradientStroke":
            return try .gradientStroke(GradientShapeFixtures.stroke(gradient(firstIndex: 1, selected: selected),
                width: property(0, index: 5, selected: selected),
                miter: property(0, index: 0, selected: selected), dashes: dashes(firstIndex: 6, selected: selected)))
        case "trim":
            return try .trimPaths(.init(start: property(0, index: 0, selected: selected),
                end: property(0, index: 1, selected: selected), offset: property(0, index: 2, selected: selected),
                mode: .individually))
        default:
            throw PAGError.invalidArgument("unknownShapeRangeFixture")
        }
    }

    /// 材料四条轨道用一份静态色标值；显式同值动画仍必须从静态范围排除。
    private static func gradient(firstIndex: Int, selected: Int) throws -> SourceGradient {
        try GradientShapeFixtures.gradient(start: property(.zero, index: firstIndex, selected: selected),
            end: property(.zero, index: firstIndex + 1, selected: selected),
            colors: property(GradientColorFixtures.colors(), index: firstIndex + 2, selected: selected),
            opacity: property(0, index: firstIndex + 3, selected: selected))
    }

    /// 原始零dash仍保留offset和八条interval，防止只遍历绘制时留下的有效间隔。
    private static func dashes(firstIndex: Int, selected: Int) throws -> SourceDashes {
        try SourceDashes(offset: property(0, index: firstIndex, selected: selected),
            intervals: (1...8).map { try property(0, index: firstIndex + $0, selected: selected) })
    }

    /// 独立预算分析语义Shape层，不创建媒体、GPU资源或公开文件实例。
    static func ranges(_ elements: [SourceShape], start: Int64 = 0, duration: Int64 = 100) throws -> StaticFrameRanges {
        var budget = FramePlanBudget(limit: 8 * 1024 * 1024)
        return try ShapeContentRanges.make(for: SceneFixtures.layer(1, start: start, duration: duration,
            content: .shape(elements)), budget: &budget)
    }
}
