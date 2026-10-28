/// 羽化蒙版的局部测量结果；顺序与采样项逐一对应，尚不包含像素附件或显示裁剪。
struct MeasuredFeatherMask: Sendable {
    /// 上游从原点和FLT_MIN开始累计右/下边界并向四周扩展10%的总体范围。
    let overall: RenderBounds
    /// 每项扩张后的路径点包围盒；None或开放项同样保留，供总体bounds累计。
    let items: [RenderBounds]
}

/// 复现TGFX路径点包围盒与FeatherMask特殊总体累计；非矩形扩张仍明确失败。
enum FeatherMaskBounds {
    /// 测量整个已采样列表；预算或取消失败不返回局部列表，也不创建GPU资源。
    static func measure(_ mask: SampledFeatherMask,
                        budget: inout FramePlanBudget) throws -> MeasuredFeatherMask {
        try Task.checkCancellation()
        var right = Float.leastNormalMagnitude
        var bottom = Float.leastNormalMagnitude
        var items: [RenderBounds] = []
        for item in mask.items {
            try Task.checkCancellation()
            try budget.reserve(stride: 32)
            // ExpandPath先做描边和PathOp，非零值只有源矩形专门分支可计算最终点范围。
            let bounds = try expandedBounds(item.path, expansion: item.expansion, budget: &budget)
            items.append(bounds)
            if Float(bounds.right) > right { right = Float(bounds.right) }
            if Float(bounds.bottom) > bottom { bottom = Float(bounds.bottom) }
        }
        // 源码仅扩展right/bottom，left/top始终从0起；Float运算顺序不可换成四边union。
        // C++字面量0.1是Double；传入outset(float,float)时才收窄，直接Float乘会差1 ulp。
        let padX = Float(Double(right) * 0.1)
        let padY = Float(Double(bottom) * 0.1)
        let outerRight = right + padX
        let outerBottom = bottom + padY
        guard [padX, padY, outerRight, outerBottom].allSatisfy(\.isFinite) else {
            throw PAGError.resourceLimitExceeded("featherMaskBounds")
        }
        try Task.checkCancellation()
        let overall = try RenderBounds(left: Double(-padX), top: Double(-padY),
                                       right: Double(outerRight), bottom: Double(outerBottom))
        return MeasuredFeatherMask(overall: overall, items: items)
    }

    /// 零扩张沿原点集；严格矩形按PathKit专门描边分支推导扩张后点界。
    private static func expandedBounds(_ path: SourcePath, expansion: Float,
                                       budget: inout FramePlanBudget) throws -> RenderBounds {
        let original = try pathPoints(path, budget: &budget)
        guard expansion != 0 else { return original }
        let strokeWidth = abs(expansion) * 2
        guard strokeWidth.isFinite, Double(strokeWidth) <= StrokeBackendLimits.standard.maximumMagnitude else {
            throw PAGError.resourceLimitExceeded("maximumStrokeMagnitude")
        }
        // 无点路径在PathKit中不生成描边，随后与自身Union/Difference仍为空。
        guard !path.points.isEmpty else { return original }
        try validateRectangle(path, bounds: original, budget: &budget)
        if strokeWidth <= 1.0 / 4096 {
            // Hairline直接复制源路径；正Union自身保留，负Difference自身归零。
            return expansion > 0 ? original : try RenderBounds(left: 0, top: 0, right: 0, bottom: 0)
        }
        let radius = strokeWidth * 0.5
        let left = Float(original.left), top = Float(original.top)
        let right = Float(original.right), bottom = Float(original.bottom)
        if expansion < 0, strokeWidth >= min(right - left, bottom - top) {
            // strokeRect没有内孔时描边覆盖整个原矩形，负差集不留下有限范围。
            return try RenderBounds(left: 0, top: 0, right: 0, bottom: 0)
        }
        let result = expansion > 0
            ? [left - radius, top - radius, right + radius, bottom + radius]
            : [left + radius, top + radius, right - radius, bottom - radius]
        guard result.allSatisfy(\.isFinite), result[0] < result[2], result[1] < result[3] else {
            throw PAGError.resourceLimitExceeded("featherMaskExpansionBounds")
        }
        return try RenderBounds(left: Double(result[0]), top: Double(result[1]),
                                right: Double(result[2]), bottom: Double(result[3]))
    }

    /// 仅承认Float化后四个不同轴对齐角点首尾闭合，和SkStroke::strokeRect的可证明输入一致。
    private static func validateRectangle(_ path: SourcePath, bounds: RenderBounds,
                                          budget: inout FramePlanBudget) throws {
        guard path.verbs == [.move, .line, .line, .line, .close], path.points.count == 4,
              bounds.left < bounds.right, bounds.top < bounds.bottom else {
            throw PAGError.unsupportedFeature("featherMaskExpansionBounds")
        }
        try budget.reserve(count: 4, stride: 8)
        let points = path.points.map { (x: Float($0.x), y: Float($0.y)) }
        let left = Float(bounds.left), top = Float(bounds.top)
        let right = Float(bounds.right), bottom = Float(bounds.bottom)
        var corners: UInt8 = 0
        for index in 0..<4 {
            try Task.checkCancellation()
            let point = points[index]
            guard (point.x == left || point.x == right),
                  (point.y == top || point.y == bottom) else {
                throw PAGError.unsupportedFeature("featherMaskExpansionBounds")
            }
            let corner = (point.x == right ? 2 : 0) + (point.y == bottom ? 1 : 0)
            let bit = UInt8(1 << corner)
            guard corners & bit == 0 else { throw PAGError.unsupportedFeature("featherMaskExpansionBounds") }
            corners |= bit
            let next = points[(index + 1) % 4]
            guard (point.x == next.x) != (point.y == next.y) else {
                throw PAGError.unsupportedFeature("featherMaskExpansionBounds")
            }
        }
        guard corners == 0b1111 else { throw PAGError.unsupportedFeature("featherMaskExpansionBounds") }
    }

    /// 有显式Move的源路径直接取PathKit会保存的所有Float点，空点列表沿SkRect返回原点零范围。
    private static func pathPoints(_ path: SourcePath,
                                   budget: inout FramePlanBudget) throws -> RenderBounds {
        var pointIndex = 0
        var hasCurrentContour = false
        var left = Float.infinity
        var top = Float.infinity
        var right = -Float.infinity
        var bottom = -Float.infinity
        for verb in path.verbs {
            try Task.checkCancellation()
            try budget.reserve(stride: 8)
            switch verb {
            case .move:
                hasCurrentContour = true
            case .line, .cubic:
                // PathKit可能为缺失Move或Close后的继续绘制隐式补点，不能只扫原始数组冒充getPoints。
                guard hasCurrentContour else { throw PAGError.unsupportedFeature("featherMaskPathSequence") }
            case .close:
                hasCurrentContour = false
            }
            try budget.reserve(count: verb.pointCount, stride: 16)
            for _ in 0..<verb.pointCount {
                let source = path.points[pointIndex]
                pointIndex += 1
                let x = Float(source.x)
                let y = Float(source.y)
                guard x.isFinite, y.isFinite else {
                    throw SceneValidator.invalid("unrepresentablePropertyValue")
                }
                left = min(left, x)
                top = min(top, y)
                right = max(right, x)
                bottom = max(bottom, y)
            }
        }
        // Close本身不追加PathKit点；零点时SkRect::setBounds返回空原点矩形。
        guard pointIndex > 0 else { return try RenderBounds(left: 0, top: 0, right: 0, bottom: 0) }
        return try RenderBounds(left: Double(left), top: Double(top),
                                right: Double(right), bottom: Double(bottom))
    }
}
