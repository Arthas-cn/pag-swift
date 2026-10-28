import Testing
@testable import pag_swift

/// 裁剪批次与作用域测试的纯语义输入，不生成PAG字节或经过正式tag25入口。
enum TrimBatchFixtures {
    /// 创建水平Line，保留独立源对象身份，便于验证前缀分配与缓存失效。
    static func line(_ length: Double, y: Double = 0) throws -> SourcePath {
        try SourcePath(verbs: [.move, .line], points: [ScenePoint(x: 0, y: y), ScenePoint(x: length, y: y)])
    }

    /// 常量Trim轨道，比例不预先夹值或按百分比缩放。
    static func source(_ start: Double = 0, _ end: Double = 1,
                       mode: SourceTrimMode = .simultaneously, offset: Double = 0) -> SourceTrimPaths {
        SourceTrimPaths(start: .init(constant: start), end: .init(constant: end), offset: .init(constant: offset), mode: mode)
    }

    /// 通过正式纯值选择与批次准备，默认无缓存候选且预算相互独立。
    static func batch(_ contours: [ShapeContour], _ source: SourceTrimPaths) throws -> PreparedTrimBatch {
        var budget = try GeometryBudget()
        return try TrimPreparation.prepare(contours, selection: TrimEvaluation.selection(source, at: 0),
                                           reusing: [], budget: &budget)
    }

    /// 要求输出已进入裁剪分支，失败不以空路径掩盖分支错误。
    static func path(_ contour: ShapeContour) throws -> PreparedTrimPath {
        guard case .trimmed(let value) = contour else {
            Issue.record("预期独立裁剪路径")
            throw PAGError.invalidArgument("expectedTrimmedPath")
        }
        return value
    }

    /// 独立计划预算下编译一层，复用只来自调用者明确提供的同源候选。
    static func prepare(_ elements: [SourceShape], frame: Int64 = 0,
                        reusing candidates: [PreparedShapeLayer] = []) throws -> PreparedShapeLayer {
        var budget = FramePlanBudget(limit: 64 * 1024 * 1024)
        return try ShapePreparation.prepare(elements, at: frame, reusing: candidates, budget: &budget)
    }

    /// 静态透明度和水平位移组，绕序与宽度变换仍由库实现求值。
    static func transform(x: Double = 0, opacity: UInt8 = 255) -> SourceShapeTransform {
        SourceShapeTransform(base: SourceTransform(anchor: .zero, position: ScenePoint(x: x, y: 0),
            scale: .one, rotation: 0, opacity: opacity), skew: 0, skewAxis: 0)
    }

    /// 提取最终覆盖顺序的paint，资源下标保持实际准备器输出。
    static func paints(_ layer: PreparedShapeLayer) -> [ShapePaint] {
        layer.instructions.compactMap { if case .fill(let paint) = $0 { paint } else { nil } }
    }
}
