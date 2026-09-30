import Testing
@testable import pag_swift

/// 从真实圆角形状到最终填充路径的后台整链；验证Conic保留期间的dash拓扑能传到端帽消费者。
struct StrokePipelineTests {
    /// 完整on覆盖的圆仍按源dash成为开放轮廓；实线保留闭合主体与孔洞，两者都能输出最终几何。
    @Test func fullCircleDashTopologyReachesOutline() throws {
        for dashed in [false, true] {
            let pattern = dashed ? try StrokeDashPattern.make(intervals: [5.8, 0.2], phase: 0) : nil
            let style = StrokeStyle(width: 0.5, cap: .butt, join: .round, miterLimit: 4, dashes: pattern)
            let rectangle = try RoundedRectangleContour.make(size: p(2, 2), position: .zero,
                roundness: 1, reversed: false, matrix: .identity)
            let geometry = try ShapeGeometry(contours: [.rectangle(rectangle)],
                stroke: ShapeStroke(style: style, matrix: .identity))
            var budget = try GeometryBudget()
            let centerline = try StrokeCenterline.make(geometry, budget: &budget)
            let path = try StrokeDashing.make(centerline, style: style, budget: &budget)
            let solid = StrokeStyle(width: style.width, cap: style.cap, join: style.join,
                miterLimit: style.miterLimit, dashes: nil)
            let result = try StrokeOutline.make(path, style: solid, tolerance: 0.001, budget: &budget)
            #expect(path.verbs.contains(.close) == !dashed)
            #expect(result.verbs.filter { $0 == .move }.count == (dashed ? 1 : 2))
            #expect(result.verbs.filter { $0 == .close }.count == (dashed ? 1 : 2))
            #expect(result.verbs.contains(.cubic))
            #expect(result.points.map(\.x).min() == -1.25 && result.points.map(\.x).max() == 1.25)
            #expect(result.points.map(\.y).min() == -1.25 && result.points.map(\.y).max() == 1.25)
        }
    }

    /// 原形状含前后paint变换时，hairline出口复原一次；全on圆不会被先转Cubic的错误测长切出缺口。
    @Test func transformedHairlineUsesFinalConversionOnly() throws {
        let matrix = try SceneAffine.scale(x: 3, y: 2).following(SceneAffine.translation(x: 10, y: 20))
        let pattern = try #require(try StrokeDashPattern.make(intervals: [5.8, 0.2], phase: 0))
        let style = StrokeStyle(width: 1.0 / 4096, cap: .square, join: .miter, miterLimit: 4, dashes: pattern)
        let rectangle = try RoundedRectangleContour.make(size: p(2, 2), position: .zero,
            roundness: 1, reversed: false, matrix: matrix)
        let stroke = try ShapeStroke(style: style, matrix: matrix)
        let geometry = try ShapeGeometry(contours: [.rectangle(rectangle)], stroke: stroke)
        var budget = try GeometryBudget()
        let centerline = try StrokeCenterline.make(geometry, budget: &budget)
        let path = try StrokeDashing.make(centerline, style: style, budget: &budget)
        let solid = StrokeStyle(width: style.width, cap: style.cap, join: style.join,
            miterLimit: style.miterLimit, dashes: nil)
        let result = try StrokeOutline.make(path, style: solid, restoration: stroke.restoration,
            tolerance: 0.001, budget: &budget)
        #expect(path.verbs == [.move] + Array(repeating: .conic(weight: Float(0.707106781)), count: 4))
        #expect(result.verbs.first == .move && !result.verbs.contains(.line) && !result.verbs.contains(.close))
        #expect(result.points.first == p(13, 20) && result.points.last == p(13, 20))
        // Float正逆变换可能留下源量化误差；这里只允许已有Float运算尺度，不能容忍重复复原。
        #expect(abs((result.points.map(\.x).min() ?? 0) - 7) < 0.00001)
        #expect(abs((result.points.map(\.x).max() ?? 0) - 13) < 0.00001)
        #expect(abs((result.points.map(\.y).min() ?? 0) - 18) < 0.00001)
        #expect(abs((result.points.map(\.y).max() ?? 0) - 22) < 0.00001)
    }

    /// 直接书写独立几何期望，不调用生产曲线求值器生成断言数据。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }
}
