import Testing
@testable import pag_swift

/// 以固定PathKit矩形判据与独立解析区域验证快路，避免用CG矩形/描边自身作为参照。
struct StrokeRectangleTests {
    /// 三边后Close、显式回起点、反向、边中起点及冗余同向/零边都识别为同一矩形。
    @Test func recognizesSourceRectangleEncodings() throws {
        let variants: [[ScenePoint]] = [
            [p(0, 0), p(10, 0), p(10, 10), p(0, 10)],
            [p(0, 0), p(10, 0), p(10, 10), p(0, 10), p(0, 0)],
            [p(0, 0), p(0, 10), p(10, 10), p(10, 0)],
            [p(5, 0), p(10, 0), p(10, 10), p(0, 10), p(0, 0)],
            [p(0, 0), p(0, 0), p(4, 0), p(10, 0), p(10, 10), p(7, 10), p(0, 10), p(0, 10)]
        ]
        for points in variants {
            let path = try path(points)
            var budget = try GeometryBudget()
            let rectangle = try #require(try StrokeRectangle.detect(path, budget: &budget))
            #expect(rectangle.left == 0 && rectangle.top == 0 && rectangle.right == 10 && rectangle.bottom == 10)
            #expect(abs(GeometryTestSupport.area(try mesh(path)) - 160) < 1e-8)
        }
    }

    /// 首边之前的Move和已闭合矩形后的纯Move不会取消源快路，也不会额外生成端帽。
    @Test func leadingAndTrailingMovesRemainHarmless() throws {
        let base = try path([.zero, p(10, 0), p(10, 10), p(0, 10)])
        let decorated = try strokePath(verbs: [.move, .move] + base.verbs + [.move, .move],
                                      points: [p(-100, -100), p(33, 40)] + base.points + [p(70, 80), p(90, 100)])
        var budget = try GeometryBudget()
        #expect(try StrokeRectangle.detect(decorated, budget: &budget) != nil)
        let expected = try outline(base, cap: .round)
        let actual = try outline(decorated, cap: .round)
        #expect(actual.verbs == expected.verbs && actual.points == expected.points)
    }

    /// 开放、回折、斜边、零面积、曲线与多个真实轮廓不能仅凭轴向bounds冒充整体闭合矩形。
    @Test func rejectsNonRectangularWholePaths() throws {
        let base = try path([.zero, p(10, 0), p(10, 10), p(0, 10)])
        let invalid = try [
            path([.zero, p(10, 0), p(10, 10), p(0, 10), .zero], closed: false),
            path([.zero, p(10, 0), .zero]),
            path([.zero, p(0, 10), p(0, 20), p(0, 10)]),
            path([.zero, p(10, 0), p(9, 10), p(0, 10)]),
            path([.zero, p(10, 0), p(5, 0), p(5, 10), p(0, 10)]),
            strokePath(verbs: [.move, .cubic, .line, .line, .close],
                       points: [.zero, p(3, 0), p(7, 0), p(10, 0), p(10, 10), p(0, 10)]),
            strokePath(verbs: [.move, .quad, .line, .line, .close],
                       points: [.zero, p(5, 0), p(10, 0), p(10, 10), p(0, 10)]),
            strokePath(verbs: [.move, .conic(weight: 0.5), .line, .line, .close],
                       points: [.zero, p(5, 0), p(10, 0), p(10, 10), p(0, 10)]),
            strokePath(verbs: base.verbs + base.verbs, points: base.points + base.points)
        ]
        for path in invalid {
            var budget = try GeometryBudget()
            #expect(try StrokeRectangle.detect(path, budget: &budget) == nil)
        }
    }

    /// 小于通用短边阈值的闭合矩形仍走完整外扩，cap三种选择不改变任何输出。
    @Test func tinyRectanglesBypassLineSuppressionAndIgnoreCaps() throws {
        let size = 1.0 / 32768
        let path = try path([.zero, p(size, 0), p(size, size), p(0, size)])
        let expected = [p(-2, -2), p(-2, size + 2), p(size + 2, size + 2), p(size + 2, -2)]
        for cap in [SourceLineCap.butt, .round, .square] {
            let result = try outline(path, cap: cap)
            #expect(result.verbs == [.move, .line, .line, .line, .close])
            #expect(result.points == expected)
        }
    }

    /// 矩形miter以Float sqrt(2)严格小于判断；紧邻下值bevel，等值和上值保留完整外角。
    @Test func miterThresholdUsesSourceFloatComparison() throws {
        let path = try path([.zero, p(10, 0), p(10, 10), p(0, 10)])
        let threshold = Float(2).squareRoot()
        for limit in [threshold.nextDown, threshold, threshold.nextUp] {
            let mesh = try mesh(path, miter: Double(limit))
            #expect(GeometryTestSupport.coverage(mesh, at: p(-1.8, -1.7)) == (limit < threshold ? 0 : 1))
            #expect(abs(GeometryTestSupport.area(mesh) - (limit < threshold ? 152 : 160)) < 1e-8)
        }
    }

    /// 宽度严格小于短边才有内孔；相等及更宽只输出外边界，三个join均符合解析面积。
    @Test func holeDisappearsAtExactShortSideWidth() throws {
        let path = try path([.zero, p(10, 0), p(10, 6), p(0, 6)])
        for width in [4.0, 6, 8] {
            for join in [SourceLineJoin.miter, .bevel, .round] {
                let result = try outline(path, width: width, join: join)
                #expect(result.verbs.filter { $0 == .move }.count == (width < 6 ? 2 : 1))
                let radius = width * 0.5
                let removed = join == .miter ? 0 : join == .bevel ? 2 * radius * radius : (4 - Double.pi) * radius * radius
                let hole = width < 6 ? (10 - width) * (6 - width) : 0
                let expected = (10 + width) * (6 + width) - removed - hole
                let mesh = try mesh(result: result)
                #expect(abs(GeometryTestSupport.area(mesh) - expected) < 0.04)
                #expect(GeometryTestSupport.coverage(mesh, at: p(4.83, 3.12)) == (width < 6 ? 0 : 1))
            }
        }
    }

    /// 极小源矩形外扩后Float角点合并为oval，仍以源conic形成完整圆而非方角或空路径。
    @Test func roundedExpansionUsesOvalAfterFloatCollapse() throws {
        let size = 1.0 / 1_073_741_824
        let path = try path([.zero, p(size, 0), p(size, size), p(0, size)])
        let mesh = try mesh(path, join: .round)
        #expect(abs(GeometryTestSupport.area(mesh) - 4 * Double.pi) < 0.02)
        #expect(GeometryTestSupport.coverage(mesh, at: p(1.8, 1.7)) == 0)
        #expect(GeometryTestSupport.coverage(mesh, at: p(1.5, 0.2)) == 1)
    }

    /// 外扩与内缩先在Float舍入，再一次性应用Double paint矩阵，避免大原点下改变源宽度。
    @Test func floatOutsetPrecedesFinalRestoration() throws {
        let x = 8_388_608.0
        let path = try path([p(x, 0), p(x + 4, 0), p(x + 4, 10), p(x, 10)])
        let source = try outline(path, width: 0.5)
        #expect(source.points == [p(x, -0.25), p(x, 10.25), p(x + 4, 10.25), p(x + 4, -0.25),
                                  p(x, 0.25), p(x + 4, 0.25), p(x + 4, 9.75), p(x, 9.75)])
        let matrix = try SceneAffine(a: -2, b: 0, c: 0, d: 3, tx: 7, ty: 9)
        let restored = try outline(path, width: 0.5, matrix: matrix)
        #expect(restored.points == source.points.map { p(7 - 2 * $0.x, 9 + 3 * $0.y) })
    }

    /// 纯Swift矩形快路仍受共享内存、element和取消约束；失败不会退回系统路径继续生成。
    @Test func rectangleOutputHonorsBudgetsAndCancellation() async throws {
        let path = try path([.zero, p(10, 0), p(10, 10), p(0, 10)])
        var budget = try GeometryBudget()
        let limits = try StrokeBackendLimits(maximumOutputElements: 4)
        #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeOutputElements")) {
            try StrokeOutline.make(path, style: style(), tolerance: 0.001, limits: limits, budget: &budget)
        }
        var tiny = try GeometryBudget(maximumBytes: 255)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try StrokeRectangle.detect(path, budget: &tiny)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try outline(path)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 创建有明确起点的折线路径；是否Close由测试显式指定。
    private func path(_ points: [ScenePoint], closed: Bool = true) throws -> StrokePath {
        try strokePath(verbs: [.move] + Array(repeating: .line, count: points.count - 1) + (closed ? [.close] : []), points: points)
    }

    /// 构造已完成求值且无dash的样式，默认宽度四用于手算区域。
    private func style(width: Double = 4, cap: SourceLineCap = .butt, join: SourceLineJoin = .miter,
                       miter: Double = 4) -> StrokeStyle {
        StrokeStyle(width: width, cap: cap, join: join, miterLimit: miter, dashes: nil)
    }

    /// 走正式内部描边入口，检验矩形分流确实优先于通用轮廓后端。
    private func outline(_ path: StrokePath, width: Double = 4, cap: SourceLineCap = .butt,
                         join: SourceLineJoin = .miter, miter: Double = 4, matrix: SceneAffine = .identity) throws -> SourcePath {
        var budget = try GeometryBudget()
        return try StrokeOutline.make(path, style: style(width: width, cap: cap, join: join, miter: miter),
                                      restoration: matrix, tolerance: 0.0005, budget: &budget)
    }

    /// 描边后进入共用折线与nonzero网格链路，面积和覆盖按独立解析值核对。
    private func mesh(_ path: StrokePath, join: SourceLineJoin = .miter, miter: Double = 4) throws -> RenderMesh {
        try mesh(result: outline(path, join: join, miter: miter))
    }

    /// 将已有完整outline折线化；此处不自行补齐或修正任何轮廓。
    private func mesh(result: SourcePath) throws -> RenderMesh {
        var budget = try GeometryBudget()
        return try GeometryTestSupport.mesh(PathFlattening.sourcePath(result, tolerance: 0.001, budget: &budget))
    }

    /// 明示解析期望的Double坐标，不调用系统矩形或描边方法。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }
    /// 用独立准备预算发布规范化描边输入，不给生产入口添加旧SourcePath兼容桥。
    private func strokePath(verbs: [StrokePathVerb], points: [ScenePoint]) throws -> StrokePath {
        var budget = try GeometryBudget()
        return try StrokePath(verbs: verbs, points: points, budget: &budget)
    }

}
