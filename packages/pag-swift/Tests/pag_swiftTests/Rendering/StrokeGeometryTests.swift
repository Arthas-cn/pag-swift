import Testing
@testable import pag_swift

/// 直接从ShapeGeometry进入共同nonzero网格，验证描边分流、端帽接角、dash与坐标消费顺序。
struct StrokeGeometryTests {
    /// 三种端帽和三种接角都经过真实网格入口；单Line面积和端点覆盖由解析矩形/圆定义。
    @Test(arguments: [SourceLineCap.butt, .round, .square])
    func capsReachSharedMesh(_ cap: SourceLineCap) throws {
        for join: SourceLineJoin in [.miter, .round, .bevel] {
            let path = try SourcePath(verbs: [.move, .line], points: [.zero, p(10, 0)])
            let geometry = try StrokeGeometryTestSupport.paths([path], style: style(width: 4, cap: cap, join: join))
            let mesh = try StrokeGeometryTestSupport.mesh(geometry, scale: 128)
            let area: Double = switch cap { case .butt: 40; case .round: 40 + 4 * .pi; case .square: 56 }
            #expect(abs(GeometryTestSupport.area(mesh) - area) < 0.02)
            #expect(GeometryTestSupport.coverage(mesh, at: p(4.1, 1.3)) == 1)
            #expect(GeometryTestSupport.coverage(mesh, at: p(-1.8, 1.8)) == (cap == .square ? 1 : 0))
        }
    }

    /// 直角中心线的Miter/Round/Bevel在外角覆盖不同，不能在网格接入时丢掉join样式。
    @Test func joinsKeepDistinctOuterCorners() throws {
        let path = try SourcePath(verbs: [.move, .line, .line], points: [p(10, 0), .zero, p(0, 10)])
        for join: SourceLineJoin in [.miter, .round, .bevel] {
            let mesh = try StrokeGeometryTestSupport.mesh(
                StrokeGeometryTestSupport.paths([path], style: style(width: 4, join: join)), scale: 128)
            #expect(GeometryTestSupport.coverage(mesh, at: p(-1.8, -1.8)) == (join == .miter ? 1 : 0))
            #expect(GeometryTestSupport.coverage(mesh, at: p(-1.2, -1.2)) == (join == .bevel ? 0 : 1))
        }
    }

    /// 两条交叉线的描边作为一次复合填充，交叉区域只有一次覆盖，不分别生成可叠加的网格。
    @Test func crossingContoursProduceSingleCoverage() throws {
        let horizontal = try SourcePath(verbs: [.move, .line], points: [p(-5, 0), p(5, 0)])
        let vertical = try SourcePath(verbs: [.move, .line], points: [p(0, -5), p(0, 5)])
        let mesh = try StrokeGeometryTestSupport.mesh(StrokeGeometryTestSupport.paths([horizontal, vertical], style: style()))
        #expect(abs(GeometryTestSupport.area(mesh) - 36) < 1e-8)
        #expect(GeometryTestSupport.coverage(mesh, at: p(0.2, 0.3)) == 1)
        #expect(GeometryTestSupport.coverage(mesh, at: p(3.2, 3.3)) == 0)
    }

    /// dash在outline之前消费，两个三单位on区间之间必须留下空白；不能以实线网格缓存替代。
    @Test func dashesReachSharedMeshBeforeStroke() throws {
        let pattern = try #require(try StrokeDashPattern.make(intervals: [3, 2], phase: 0))
        let path = try SourcePath(verbs: [.move, .line], points: [.zero, p(10, 0)])
        let mesh = try StrokeGeometryTestSupport.mesh(StrokeGeometryTestSupport.paths([path], style: style(dashes: pattern)))
        #expect(abs(GeometryTestSupport.area(mesh) - 12) < 0.00001)
        #expect(GeometryTestSupport.coverage(mesh, at: p(1.3, 0.2)) == 1)
        #expect(GeometryTestSupport.coverage(mesh, at: p(4.3, 0.2)) == 0)
        #expect(GeometryTestSupport.coverage(mesh, at: p(6.3, 0.2)) == 1)
        #expect(GeometryTestSupport.coverage(mesh, at: p(9.3, 0.2)) == 0)
    }

    /// 奇异矩阵只把中心线压到竖直方向，描边仍有面积；它必须先于普通fill的奇异过滤。
    @Test func singularPaintKeepsStrokeCenterline() throws {
        let path = try SourcePath(verbs: [.move, .line], points: [.zero, p(10, 10)])
        let matrix = try SceneAffine.scale(x: 0, y: 1)
        let geometry = try StrokeGeometryTestSupport.paths([path], style: style(), matrix: matrix)
        let mesh = try StrokeGeometryTestSupport.mesh(geometry)
        #expect(abs(GeometryTestSupport.area(mesh) - 20) < 1e-8)
        #expect(GeometryTestSupport.coverage(mesh, at: p(0.3, 4.2)) == 1)
    }

    /// 非均匀paint复原只能做一次；stroke沿局部宽度生成，最终图层矩阵决定解析面积与范围。
    @Test func paintRestorationIsAppliedExactlyOnce() throws {
        let path = try SourcePath(verbs: [.move, .line], points: [.zero, p(10, 0)])
        let matrix = try SceneAffine.scale(x: 3, y: 2).following(SceneAffine.translation(x: 10, y: 20))
        let mesh = try StrokeGeometryTestSupport.mesh(StrokeGeometryTestSupport.paths([path], style: style(), matrix: matrix))
        #expect(abs(GeometryTestSupport.area(mesh) - 120) < 0.00001)
        #expect(GeometryTestSupport.coverage(mesh, at: p(24.2, 21.3)) == 1)
        #expect(GeometryTestSupport.coverage(mesh, at: p(24.2, 23.3)) == 0)
    }

    /// hairline保留闭合三角形的fill语义；孤立零Line的非hairline圆帽仍必须生成面积。
    @Test func hairlineAndDegenerateCapsUseDifferentBranches() throws {
        let triangle = try SourcePath(verbs: [.move, .line, .line, .close], points: [.zero, p(10, 0), p(0, 10)])
        let fill = try StrokeGeometryTestSupport.mesh(StrokeGeometryTestSupport.paths([triangle], style: style(width: 1.0 / 4096)))
        #expect(abs(GeometryTestSupport.area(fill) - 50) < 1e-8)
        let point = try SourcePath(verbs: [.move, .line], points: [p(3, 4), p(3, 4)])
        let cap = try StrokeGeometryTestSupport.mesh(StrokeGeometryTestSupport.paths([point], style: style(width: 4, cap: .round)), scale: 128)
        #expect(abs(GeometryTestSupport.area(cap) - 4 * .pi) < 0.02)
        #expect(GeometryTestSupport.coverage(cap, at: p(3.1, 4.3)) == 1)
    }

    /// 普通rrect和oval闭缝dash最终都能进入同一网格；全on圆保持源Q边界而不是理想圆的面积。
    @Test func roundedContoursRetainSourceQuadraticBoundary() throws {
        let pattern = try #require(try StrokeDashPattern.make(intervals: [5.8, 0.2], phase: 0))
        let circle = try StrokeGeometryTestSupport.circle(style: style(width: 0.5, dashes: pattern))
        let mesh = try StrokeGeometryTestSupport.mesh(circle, scale: 128)
        // 源两侧各四段Q，单个四分Q封闭到原点的面积为5r²/6；外内半径分别为1.25/.75。
        #expect(abs(GeometryTestSupport.area(mesh) - 10.0 / 3) < 0.01)
        #expect(GeometryTestSupport.coverage(mesh, at: p(0.05, 0.03)) == 0)
        #expect(GeometryTestSupport.coverage(mesh, at: p(0.9, 0.2)) == 1)
        let rectangle = try RoundedRectangleContour.make(size: p(40, 20), position: .zero,
            roundness: 4, reversed: false, matrix: .identity)
        let rounded = try ShapeGeometry(contours: [.rectangle(rectangle)], stroke: ShapeStroke(style: style(), matrix: .identity))
        let outline = try StrokeGeometryTestSupport.mesh(rounded)
        #expect(GeometryTestSupport.coverage(outline, at: p(19.7, 0.3)) == 1)
        #expect(GeometryTestSupport.coverage(outline, at: p(0.2, 0.3)) == 0)
    }

    /// 成功的Cubic和Line与矩形Conic累计到同一次描边；各自内部和空洞由独立坐标核验。
    @Test func mixedCenterlineCurvesReachOneMesh() throws {
        let path = try SourcePath(verbs: [.move, .cubic, .line],
            points: [.zero, p(0, 8), p(4, 12), p(12, 12), p(20, 12)])
        let circle = try RoundedRectangleContour.make(size: p(8, 8), position: p(30, 0),
            roundness: 4, reversed: false, matrix: .identity)
        let geometry = try ShapeGeometry(contours: [.path(path, matrix: .identity), .rectangle(circle)],
            stroke: ShapeStroke(style: style(cap: .round), matrix: .identity))
        let mesh = try StrokeGeometryTestSupport.mesh(geometry, scale: 16)
        // Cubic的t=.5位置为(3,9)，稍偏离中心和网格边界；圆环参照点半径接近4。
        for point in [p(3.1, 9.1), p(15.3, 12.2), p(33.2, 2.3)] {
            #expect(GeometryTestSupport.coverage(mesh, at: point) == 1)
        }
        #expect(GeometryTestSupport.coverage(mesh, at: p(30.2, 0.3)) == 0)
        #expect(GeometryTestSupport.coverage(mesh, at: p(3.1, 5.1)) == 0)
    }

    /// 首尾on跨越Close接缝时是同一接角；Butt端帽不能将该处切成两条独立短线。
    @Test func closedDashSeamRetainsJoinCoverage() throws {
        let path = try SourcePath(verbs: [.move, .line, .line, .line, .close],
            points: [.zero, p(10, 0), p(10, 10), p(0, 10)])
        let pattern = try #require(try StrokeDashPattern.make(intervals: [10, 20], phase: 0))
        let mesh = try StrokeGeometryTestSupport.mesh(StrokeGeometryTestSupport.paths([path], style: style(dashes: pattern)))
        // 源dash输出(0,10)→(0,0)→(10,0)，Miter填满左上外角；右边和下边均处off。
        #expect(abs(GeometryTestSupport.area(mesh) - 40) < 1e-8)
        #expect(GeometryTestSupport.coverage(mesh, at: p(-0.7, -0.6)) == 1)
        #expect(GeometryTestSupport.coverage(mesh, at: p(9.7, 4.3)) == 0)
        #expect(GeometryTestSupport.coverage(mesh, at: p(4.3, 9.7)) == 0)
    }

    /// 直接写场景坐标，使解析期望与生产求值器独立。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { StrokeGeometryTestSupport.point(x, y) }

    /// 默认Butt实线便于解析面积，测试按需显式改变样式。
    private func style(width: Double = 2, cap: SourceLineCap = .butt, join: SourceLineJoin = .miter,
                       dashes: StrokeDashPattern? = nil) -> StrokeStyle {
        StrokeGeometryTestSupport.style(width: width, cap: cap, join: join, dashes: dashes)
    }
}

/// 描边网格与精度回归共用的纯值夹具；只构造输入，不生成数值期望或绕开真实网格入口。
enum StrokeGeometryTestSupport {
    /// 构造有限场景点；失败输入由各测试显式准备。
    static func point(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }

    /// 默认宽2的实线样式，颜色和alpha不属于几何测试输入。
    static func style(width: Double = 2, cap: SourceLineCap = .butt, join: SourceLineJoin = .miter,
                      dashes: StrokeDashPattern? = nil) -> StrokeStyle {
        StrokeStyle(width: width, cap: cap, join: join, miterLimit: 4, dashes: dashes)
    }

    /// 轮廓和paint使用相同矩阵，中心线必须经历已有的独立Float正逆变换。
    static func paths(_ paths: [SourcePath], style: StrokeStyle, matrix: SceneAffine = .identity) throws -> ShapeGeometry {
        try ShapeGeometry(contours: paths.map { .path($0, matrix: matrix) }, stroke: ShapeStroke(style: style, matrix: matrix))
    }

    /// 源单位圆由实际RoundedRectangleContour生成四Conic，不手工将圆先变Cubic。
    static func circle(style: StrokeStyle) throws -> ShapeGeometry {
        let circle = try RoundedRectangleContour.make(size: point(2, 2), position: .zero,
            roundness: 1, reversed: false, matrix: .identity)
        return try ShapeGeometry(contours: [.rectangle(circle)], stroke: ShapeStroke(style: style, matrix: .identity))
    }

    /// 使用与RenderGeometryCache冷路径相同的真实准备器，scale只收紧显示精度而不改变源几何。
    static func mesh(_ geometry: ShapeGeometry, scale: Double = 1) throws -> RenderMesh {
        var budget = try GeometryBudget()
        return try RenderGeometrySource.shape(geometry).prepare(
            precision: GeometryPrecision(transform: .scale(x: scale, y: scale)), budget: &budget)
    }
}
