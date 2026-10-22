import Testing
@testable import pag_swift

/// Append合并必须变成一个可重复消费的原生曲线路径，并清掉合并前的paint。
struct ShapeMergePathsTests {
    /// 此前直接/子组路径按源序合并；合并前红paint消失，后续蓝Fill与Stroke共享单一路径。
    @Test func appendPreservesCurvesNestedPathsAndLaterStroke() throws {
        let square = try ShapePathFixtures.square(20)
        let cubic = try SourcePath(verbs: [.move, .cubic, .close], points: [
            ScenePoint(x: 50, y: 10), ScenePoint(x: 55, y: 10),
            ScenePoint(x: 65, y: 30), ScenePoint(x: 70, y: 30)
        ])
        let contents: [SourceShape] = [
            .path(.init(constant: square)),
            .fill(color: .defaultFill, opacity: 255),
            .group(ShapePropertyFixtures.group(), [.path(.init(constant: cubic))]),
            .mergePaths(.merge),
            .fill(color: SceneColor(red: 0, green: 0, blue: 255), opacity: 255),
            .stroke(StrokeFixtures.make())
        ]
        let prepared = try ShapePropertyFixtures.prepare(contents)
        let paints = ShapePropertyFixtures.paints(prepared)
        #expect(paints.count == 2)
        // Below绘制会逆序输出，检查颜色集合而非把编码顺序误当最终绘制顺序。
        let colors = try paints.map { try $0.material.solidColor() }
        #expect(colors.contains(SceneColor(red: 0, green: 0, blue: 255)))
        #expect(!colors.contains(.defaultFill))
        for geometry in prepared.geometries {
            let contour = try #require(geometry.contours.first)
            #expect(geometry.contours.count == 1)
            guard case .trimmed(let merged) = contour else {
                Issue.record("Append结果必须作为一条原生曲线路径供Fill和Stroke共同消费")
                continue
            }
            #expect(merged.path.verbs == [.move, .line, .line, .line, .close, .move, .cubic, .close])
            #expect(merged.path.points.count == 8)
        }
    }

    /// 四种面积运算均清掉先前Paint，并输出一条可供后续描边或Trim消费的路径。
    @Test(arguments: [SourceMergePathsMode.add, .subtract, .intersect, .excludeIntersections])
    func booleanProducesOneReusablePath(_ mode: SourceMergePathsMode) throws {
        let first = SourceShape.rectangle(reversed: false, size: ScenePoint(x: 40, y: 40),
                                           position: ScenePoint(x: 30, y: 40), roundness: 0)
        let second = SourceShape.rectangle(reversed: false, size: ScenePoint(x: 40, y: 40),
                                            position: ScenePoint(x: 50, y: 40), roundness: 0)
        let prepared = try ShapePropertyFixtures.prepare([
            first, .fill(color: .defaultFill, opacity: 255), second, .mergePaths(mode),
            .fill(color: SceneColor(red: 0, green: 0, blue: 255), opacity: 255),
            .stroke(StrokeFixtures.make())
        ])
        #expect(ShapePropertyFixtures.paints(prepared).count == 2)
        for geometry in prepared.geometries {
            #expect(geometry.contours.count == 1)
            guard case .trimmed(let path) = try #require(geometry.contours.first) else {
                Issue.record("面积布尔结果必须以单条原生路径进入Fill和Stroke")
                continue
            }
            #expect(!path.path.verbs.isEmpty)
        }
    }

    /// 不相交结果仍占一条零verb路径并清除旧Paint，不能误把旧路径留在画面。
    @Test func disjointIntersectionKeepsEmptyResultPath() throws {
        let first = SourceShape.rectangle(reversed: false, size: ScenePoint(x: 20, y: 20),
                                           position: ScenePoint(x: 20, y: 40), roundness: 0)
        let second = SourceShape.rectangle(reversed: false, size: ScenePoint(x: 20, y: 20),
                                            position: ScenePoint(x: 70, y: 40), roundness: 0)
        let prepared = try ShapePropertyFixtures.prepare([
            first, .fill(color: .defaultFill, opacity: 255), second, .mergePaths(.intersect),
            .fill(color: SceneColor(red: 0, green: 0, blue: 255), opacity: 255)
        ])
        #expect(ShapePropertyFixtures.paints(prepared).count == 1)
        let contour = try #require(prepared.geometries.first?.contours.first)
        guard case .trimmed(let path) = contour else {
            Issue.record("不相交的Boolean仍应产出空的单路径")
            return
        }
        #expect(path.path.verbs.isEmpty)
    }

    /// Merge之前无路径时上游保持组内容不变，Boolean模式也不应拒绝后续路径。
    @Test func mergeWithoutEarlierPathDoesNothing() throws {
        let path = try ShapePathFixtures.square(20)
        let prepared = try ShapePropertyFixtures.prepare([
            .mergePaths(.intersect), .path(.init(constant: path)),
            .fill(color: .defaultFill, opacity: 255)
        ])
        #expect(ShapePropertyFixtures.paints(prepared).count == 1)
        #expect(prepared.geometries.count == 1)
    }

    /// 仅一条旧路径时五种模式都直接保留首路径并清组，不能因尚无第二操作数而拒绝Boolean模式。
    @Test(arguments: SourceMergePathsMode.allCases)
    func singlePathKeepsFirstOperand(_ mode: SourceMergePathsMode) throws {
        let path = try ShapePathFixtures.square(20)
        let prepared = try ShapePropertyFixtures.prepare([
            .path(.init(constant: path)), .fill(color: .defaultFill, opacity: 255),
            .mergePaths(mode), .fill(color: SceneColor(red: 0, green: 0, blue: 255), opacity: 255)
        ])
        #expect(ShapePropertyFixtures.paints(prepared).count == 1)
        let contour = try #require(prepared.geometries.first?.contours.first)
        guard case .trimmed(let value) = contour else {
            Issue.record("单路径合并应保留可供后续Stroke/Trim消费的原生路径")
            return
        }
        #expect(value.path.verbs == [.move, .line, .line, .line, .close])
    }

    /// Merge之后的Trim应把两条原路径看成一个输入，不能绕过合并重新裁剪两份旧路径。
    @Test func laterTrimConsumesOneMergedPath() throws {
        let first = try TrimBatchFixtures.line(20)
        let second = try TrimBatchFixtures.line(20, y: 10)
        let prepared = try ShapePropertyFixtures.prepare([
            .path(.init(constant: first)), .path(.init(constant: second)),
            .mergePaths(.merge), .trimPaths(TrimBatchFixtures.source(0, 0.5)),
            .fill(color: .defaultFill, opacity: 255)
        ])
        #expect(prepared.trimBatchesByModifier[0]?.inputs.count == 1)
        #expect(prepared.geometries.count == 1)
        #expect(prepared.geometries[0].contours.count == 1)
    }

    /// 面积交集后的Trim也只接收一个结果路径，不能回头裁剪两个原始矩形。
    @Test func laterTrimConsumesOneBooleanPath() throws {
        let first = SourceShape.rectangle(reversed: false, size: ScenePoint(x: 40, y: 40),
                                           position: ScenePoint(x: 30, y: 40), roundness: 0)
        let second = SourceShape.rectangle(reversed: false, size: ScenePoint(x: 40, y: 40),
                                            position: ScenePoint(x: 50, y: 40), roundness: 0)
        let prepared = try ShapePropertyFixtures.prepare([
            first, second, .mergePaths(.intersect),
            .trimPaths(TrimBatchFixtures.source(0, 0.5)),
            .stroke(StrokeFixtures.make())
        ])
        #expect(prepared.trimBatchesByModifier[0]?.inputs.count == 1)
        #expect(prepared.geometries.count == 1)
        #expect(prepared.geometries[0].contours.count == 1)
    }

    /// 同步系统Boolean不可中途取消，调用前必须按最坏交点工作量拒绝过小预算。
    @Test func booleanPrechargesWorstCaseWork() throws {
        var setup = try GeometryBudget()
        let first = try squarePath(x: 10, budget: &setup)
        let second = try squarePath(x: 20, budget: &setup)
        var small = try GeometryBudget(maximumWork: 100)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try ShapeMergeBoolean.make([first, second], mode: .intersect, budget: &small)
        }
        #expect(small.work > 0)
    }

    /// 系统CGPath没有有理Conic指令；尚未证明等价的曲线不能静默降级成二次Bezier。
    @Test func conicBooleanRemainsExplicitlyUnsupported() throws {
        var budget = try GeometryBudget()
        let conic = try StrokePath(verbs: [.move, .conic(weight: 0.7), .close], points: [
            ScenePoint(x: 10, y: 10), ScenePoint(x: 20, y: 0), ScenePoint(x: 30, y: 10)
        ], budget: &budget)
        let square = try squarePath(x: 10, budget: &budget)
        #expect(throws: PAGError.unsupportedFeature("mergePathsConicBoolean")) {
            try ShapeMergeBoolean.make([conic, square], mode: .intersect, budget: &budget)
        }
    }

    /// 只供预算门禁的四边形，闭合指令和点列均来自原生路径模型。
    private func squarePath(x: Double, budget: inout GeometryBudget) throws -> StrokePath {
        try StrokePath(verbs: [.move, .line, .line, .line, .close], points: [
            ScenePoint(x: x, y: 10), ScenePoint(x: x + 20, y: 10),
            ScenePoint(x: x + 20, y: 30), ScenePoint(x: x, y: 30)
        ], budget: &budget)
    }
}
