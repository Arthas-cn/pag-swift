import Testing
@testable import pag_swift

/// 圆角效果锁定SkPath迭代器的隐式闭合线及线段两端半径截断。
struct RoundCornersPathEffectTests {
    /// 闭合矩形的四个角各产生一个原角点控制的Quad，Close前须先处理隐式第四边。
    @Test func closedRectangleRoundsAllFourCorners() throws {
        var budget = try GeometryBudget()
        let source = try StrokePath(verbs: [.move, .line, .line, .line, .close],
            points: [ScenePoint(x: 0, y: 0), ScenePoint(x: 100, y: 0),
                     ScenePoint(x: 100, y: 100), ScenePoint(x: 0, y: 100)], budget: &budget)
        let result = try RoundCornersPathEffect.apply(source, radius: 10, budget: &budget)
        #expect(result.verbs == [.move, .line, .quad, .line, .quad, .line, .quad, .line, .quad, .close])
        #expect(result.points == [
            ScenePoint(x: 10, y: 0), ScenePoint(x: 90, y: 0),
            ScenePoint(x: 100, y: 0), ScenePoint(x: 100, y: 10), ScenePoint(x: 100, y: 90),
            ScenePoint(x: 100, y: 100), ScenePoint(x: 90, y: 100), ScenePoint(x: 10, y: 100),
            ScenePoint(x: 0, y: 100), ScenePoint(x: 0, y: 90), ScenePoint(x: 0, y: 10),
            ScenePoint(x: 0, y: 0), ScenePoint(x: 10, y: 0)])
    }

    /// 非正半径按上游MakeCorner返回空效果，必须共享原路径而不生成近似几何。
    @Test func nonpositiveRadiusKeepsOriginalPath() throws {
        var budget = try GeometryBudget()
        let source = try StrokePath(verbs: [.move, .line],
            points: [.zero, ScenePoint(x: 10, y: 0)], budget: &budget)
        let result = try RoundCornersPathEffect.apply(source, radius: 0, budget: &budget)
        #expect(result.verbs == source.verbs && result.points == source.points)
    }
}
