import Testing
@testable import pag_swift

/// 文字路径沿曲线取点、反向、闭合取余和开放端点外推的纯值边界。
struct TextPathGeometryTests {
    /// 水平开放路径在起点前与终点后沿单位切线延长，不能把大边距钳到端点。
    @Test func openLineExtendsBothEnds() throws {
        let path = try SourcePath(verbs: [.move, .line],
            points: [ScenePoint(x: 0, y: 0), ScenePoint(x: 100, y: 0)])
        var budget = try GeometryBudget()
        let geometry = try TextPathGeometry(path: path, reversed: false, budget: &budget)
        #expect(geometry.length == 100 && !geometry.isClosed)
        for (distance, expected) in [(-508.0, -508.0), (0, 0), (50, 50), (386, 386)] {
            let result = try geometry.sample(at: distance, budget: &budget)
            #expect(abs(result.position.x - expected) < 0.001)
            #expect(abs(result.position.y) < 0.001)
            #expect(abs(result.tangent.x - 1) < 0.001 && abs(result.tangent.y) < 0.001)
        }
    }

    /// 反向必须先反转完整曲线，首尾及端点外推的切线都随之反向。
    @Test func reversedLineChangesOriginAndDirection() throws {
        let path = try SourcePath(verbs: [.move, .line],
            points: [ScenePoint(x: 0, y: 0), ScenePoint(x: 100, y: 0)])
        var budget = try GeometryBudget()
        let geometry = try TextPathGeometry(path: path, reversed: true, budget: &budget)
        let start = try geometry.sample(at: -20, budget: &budget)
        let middle = try geometry.sample(at: 50, budget: &budget)
        #expect(abs(start.position.x - 120) < 0.001 && abs(start.tangent.x + 1) < 0.001)
        #expect(abs(middle.position.x - 50) < 0.001)
    }

    /// 闭合方形沿周长取余，负距离与超长距离不得按开放端点延长。
    @Test func closedContourWrapsDistance() throws {
        let path = try SourcePath(verbs: [.move, .line, .line, .line, .close], points: [
            ScenePoint(x: 0, y: 0), ScenePoint(x: 10, y: 0),
            ScenePoint(x: 10, y: 10), ScenePoint(x: 0, y: 10)])
        var budget = try GeometryBudget()
        let geometry = try TextPathGeometry(path: path, reversed: false, budget: &budget)
        #expect(geometry.isClosed && geometry.length == 40)
        let normal = try geometry.sample(at: 5, budget: &budget)
        let wrapped = try geometry.sample(at: 45, budget: &budget)
        #expect(abs(normal.position.x - wrapped.position.x) < 0.001)
        #expect(abs(normal.position.y - wrapped.position.y) < 0.001)
        let negative = try geometry.sample(at: -5, budget: &budget)
        #expect(abs(negative.position.x) < 0.001 && abs(negative.position.y - 5) < 0.001)
    }

    /// 只有Move的零长度引用不能给所有字形伪造横向取点。
    @Test func emptyPathIsRejected() throws {
        let path = try SourcePath(verbs: [.move], points: [ScenePoint(x: 1, y: 2)])
        var budget = try GeometryBudget()
        #expect(throws: PAGError.unsupportedFeature("textPathEmpty")) {
            try TextPathGeometry(path: path, reversed: false, budget: &budget)
        }
    }
}
