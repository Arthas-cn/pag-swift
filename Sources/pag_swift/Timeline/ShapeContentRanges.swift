/// Shape内容的静态时间分析；不包含外层图层变换，不选择Picture或生成绘制资源。
enum ShapeContentRanges {
    /// 从源层可见期分析全部Shape轨道，返回图层局部闭区间；非Shape、预算或取消均抛错。
    static func make(for layer: SourceLayer, budget: inout FramePlanBudget) throws -> StaticFrameRanges {
        try Task.checkCancellation()
        guard case .shape(let elements) = layer.content else { throw SceneValidator.invalid("expectedShapeContent") }
        var result = try StaticFrameRanges(startFrame: layer.startFrame, duration: layer.durationFrames, budget: &budget)
        // 上游ContentCache先按所属合成帧排除内容变化，最后才换算为内容局部帧。
        result = try excluding(elements, from: result, budget: &budget)
        return try result.relative(to: layer.startFrame, budget: &budget)
    }

    /// 在任意父合成静态范围上排除Shape内容轨道；供Vector按Layer轨道之后复用源遍历顺序。
    static func excluding(_ elements: [SourceShape], from ranges: StaticFrameRanges,
                          budget: inout FramePlanBudget) throws -> StaticFrameRanges {
        var result = ranges
        try exclude(elements, from: &result, depth: 0, budget: &budget)
        return result
    }

    /// 按源编码顺序遍历；即使范围已空仍验证后续深度和预算，不按可见paint删属性。
    private static func exclude(_ elements: [SourceShape], from result: inout StaticFrameRanges,
                                depth: Int, budget: inout FramePlanBudget) throws {
        try visit(budget: &budget)
        guard depth <= 64 else { throw PAGError.resourceLimitExceeded("maximumShapeDepth") }
        for element in elements {
            try visit(budget: &budget)
            switch element {
            case .group(let transform, let children):
                try exclude(transform.anchor, from: &result, budget: &budget)
                try exclude(transform.position, from: &result, budget: &budget)
                try exclude(transform.scale, from: &result, budget: &budget)
                try exclude(transform.skew, from: &result, budget: &budget)
                try exclude(transform.skewAxis, from: &result, budget: &budget)
                try exclude(transform.rotation, from: &result, budget: &budget)
                try exclude(transform.opacity, from: &result, budget: &budget)
                try exclude(children, from: &result, depth: depth + 1, budget: &budget)
            case .rectangle(let value):
                try exclude(value.position, from: &result, budget: &budget)
                try exclude(value.size, from: &result, budget: &budget)
                try exclude(value.roundness, from: &result, budget: &budget)
            case .ellipse(let value):
                try exclude(value.position, from: &result, budget: &budget)
                try exclude(value.size, from: &result, budget: &budget)
            case .polyStar(let value):
                try exclude(value.points, from: &result, budget: &budget)
                try exclude(value.position, from: &result, budget: &budget)
                try exclude(value.rotation, from: &result, budget: &budget)
                // Polygon也保留内半径/圆度的变化，不能复用几何消费的跳过逻辑。
                try exclude(value.innerRadius, from: &result, budget: &budget)
                try exclude(value.outerRadius, from: &result, budget: &budget)
                try exclude(value.innerRoundness, from: &result, budget: &budget)
                try exclude(value.outerRoundness, from: &result, budget: &budget)
            case .path(let property):
                try exclude(property, from: &result, budget: &budget)
            case .fill(let value):
                try exclude(value.color, from: &result, budget: &budget)
                try exclude(value.opacity, from: &result, budget: &budget)
            case .stroke(let value):
                try exclude(value.miterLimit, from: &result, budget: &budget)
                try exclude(value.color, from: &result, budget: &budget)
                try exclude(value.opacity, from: &result, budget: &budget)
                try exclude(value.width, from: &result, budget: &budget)
                try exclude(value.dashes, from: &result, budget: &budget)
            case .gradientFill(let value):
                try exclude(value.gradient, from: &result, budget: &budget)
            case .gradientStroke(let value):
                try exclude(value.miterLimit, from: &result, budget: &budget)
                try exclude(value.gradient, from: &result, budget: &budget)
                try exclude(value.width, from: &result, budget: &budget)
                try exclude(value.dashes, from: &result, budget: &budget)
            case .trimPaths(let value):
                try exclude(value.start, from: &result, budget: &budget)
                try exclude(value.end, from: &result, budget: &budget)
                try exclude(value.offset, from: &result, budget: &budget)
            case .mergePaths:
                // MergePaths是固定操作，静态性只取决于它消费的此前路径属性。
                break
            case .repeater(let value):
                try exclude(value.copies, from: &result, budget: &budget)
                try exclude(value.offset, from: &result, budget: &budget)
                try exclude(value.anchor, from: &result, budget: &budget)
                try exclude(value.position, from: &result, budget: &budget)
                try exclude(value.scale, from: &result, budget: &budget)
                try exclude(value.rotation, from: &result, budget: &budget)
                try exclude(value.startOpacity, from: &result, budget: &budget)
                try exclude(value.endOpacity, from: &result, budget: &budget)
            case .roundCorners(let radius):
                try exclude(radius, from: &result, budget: &budget)
            }
        }
    }

    /// 每条属性（含常量）先计访问成本，再由时间内核处理所有关键帧，不求值端点颜色或路径。
    private static func exclude<Value>(_ property: SourceProperty<Value>, from result: inout StaticFrameRanges,
                                       budget: inout FramePlanBudget) throws {
        try visit(budget: &budget)
        result = try result.excluding(property, budget: &budget)
    }

    /// 两类渐变共有的源顺序是起点、终点、颜色表、透明度，保留所有轨道。
    private static func exclude(_ gradient: SourceGradient, from result: inout StaticFrameRanges,
                                budget: inout FramePlanBudget) throws {
        try exclude(gradient.start, from: &result, budget: &budget)
        try exclude(gradient.end, from: &result, budget: &budget)
        try exclude(gradient.colors, from: &result, budget: &budget)
        try exclude(gradient.opacity, from: &result, budget: &budget)
    }

    /// 仅有Custom dash才存在offset；每条interval均参与内容变化，即使当前绘制时归一化为零。
    private static func exclude(_ dashes: SourceDashes?, from result: inout StaticFrameRanges,
                                budget: inout FramePlanBudget) throws {
        guard let dashes else { return }
        try exclude(dashes.offset, from: &result, budget: &budget)
        for interval in dashes.intervals { try exclude(interval, from: &result, budget: &budget) }
    }

    /// 对列表、元素与属性统一预收工作成本，并在递归进入或读取下一项前响应取消。
    private static func visit(budget: inout FramePlanBudget) throws {
        try Task.checkCancellation()
        try budget.reserve(stride: 32)
    }
}
