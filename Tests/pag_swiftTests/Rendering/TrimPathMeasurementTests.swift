import Testing
@testable import pag_swift

/// Trim测量与提取的轮廓选择、越界距离及闭合接缝，不使用渲染像素推断路径拓扑。
struct TrimPathMeasurementTests {
    /// 跳过纯Move和零段后仅测首个有长度轮廓，反转路径后对应选择原末尾可测轮廓。
    @Test func firstMeasurableContourChangesAfterReversal() throws {
        var budget = try GeometryBudget()
        let path = try StrokePath(verbs: [.move, .move, .line, .move, .line, .move, .line, .move],
            points: [p(99), p(0), p(0), p(10), p(20), p(30), p(50), p(88)], budget: &budget)
        let first = try #require(try TrimPathMeasurement.first(in: path, budget: &budget))
        #expect(first.length == 10)
        #expect(try extract(first, from: 0, to: 10).points == [p(10), p(20)])
        let reversed = try TrimPathReversal.reversed(path, budget: &budget)
        let other = try #require(try TrimPathMeasurement.first(in: reversed, budget: &budget))
        #expect(other.length == 20)
        #expect(try extract(other, from: 0, to: 20).points == [p(50), p(30)])
    }

    /// 只钳负start和超长stop；完全越界不追加，恰好接触起终点保留Move加零Line。
    @Test func asymmetricDistanceClampKeepsTouchingRanges() throws {
        let value = try measure(verbs: [.move, .line], points: [p(0), p(10)])
        for (start, end): (Float, Float) in [(-5, -1), (11, 12)] {
            var writer = TrimPathWriter(budget: try GeometryBudget())
            #expect(try TrimPathMeasurement.append(value, from: start, to: end, to: &writer) == false)
            #expect(writer.verbs.isEmpty && writer.points.isEmpty)
        }
        #expect(try extract(value, from: -5, to: 0).points == [p(0), p(0)])
        #expect(try extract(value, from: 10, to: 12).points == [p(10), p(10)])
        #expect(try extract(value, from: -5, to: 12).points == [p(0), p(10)])
    }

    /// 跨闭合接缝分两次getSegment，第二段另起Move；顶点起切的零Line保留，永不补Close。
    @Test func wrappedSquareKeepsTwoOpenContours() throws {
        let value = try measure(verbs: [.move, .line, .line, .line, .close],
                                points: [p(0, 0), p(10, 0), p(10, 10), p(0, 10)])
        #expect(value.length == 40 && value.isClosed)
        var writer = TrimPathWriter(budget: try GeometryBudget())
        #expect(try TrimPathMeasurement.append(value, from: 30, to: 40, to: &writer))
        #expect(try TrimPathMeasurement.append(value, from: 0, to: 10, to: &writer))
        let result = try writer.finish()
        #expect(result.verbs == [.move, .line, .line, .move, .line])
        #expect(result.points == [p(0, 10), p(0, 10), p(0, 0), p(0, 0), p(10, 0)])
    }

    /// 源Float几何测量深度和非有限距离错误原样失败，不能当作首个空轮廓继续寻找。
    @Test func failedMeasurementAndInvalidDistanceDoNotDisappear() throws {
        var budget = try GeometryBudget()
        let path = try StrokePath(verbs: [.move, .cubic, .move, .line],
            points: [p(0), p(0, 12), p(12, 12), p(12), p(0), p(10)], budget: &budget)
        var limited = try GeometryBudget(maximumDepth: 0)
        #expect(throws: PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")) {
            try TrimPathMeasurement.first(in: path, budget: &limited)
        }
        let line = try measure(verbs: [.move, .line], points: [p(0), p(10)])
        for range: (Float, Float) in [(.nan, 1), (0, .infinity)] {
            #expect(throws: PAGError.renderingFailure("trimPrecision")) { try extract(line, from: range.0, to: range.1) }
        }
    }

    /// 建立纯语义曲线并调用通用首轮廓测量，不先施加描边样式或规模限制。
    private func measure(verbs: [StrokePathVerb], points: [ScenePoint]) throws -> StrokeDashMeasure {
        var budget = try GeometryBudget()
        let path = try StrokePath(verbs: verbs, points: points, budget: &budget)
        return try #require(try TrimPathMeasurement.first(in: path, budget: &budget))
    }

    /// 提取成功距离区间并保留完整临时曲线，失败不会发布writer的部分数组。
    private func extract(_ measure: StrokeDashMeasure, from start: Float, to end: Float) throws -> StrokePath {
        var writer = TrimPathWriter(budget: try GeometryBudget())
        #expect(try TrimPathMeasurement.append(measure, from: start, to: end, to: &writer))
        return try writer.finish()
    }

    /// 直接提供可手算点，不通过生产几何生成器构建期望路径。
    private func p(_ x: Double, _ y: Double = 0) -> ScenePoint { ScenePoint(x: x, y: y) }
}
