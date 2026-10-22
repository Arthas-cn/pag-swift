import CoreGraphics
import Testing
@testable import pag_swift

/// 正式缓存入口的扩张描边与独立系统路径金值；不编码虚构PAG字节或创建demo。
struct MaskExpansionGeometryTests {
    /// 方形原路径与Butt/Round系统描边逐点对照，正并和负差都须保留孔洞及圆角。
    @Test func positiveAndNegativeExpansionMatchIndependentStrokePoints() throws {
        let source = try ShapePathFixtures.square(10)
        let original = CGMutablePath()
        original.move(to: CGPoint(x: 10, y: 10))
        original.addLine(to: CGPoint(x: 20, y: 10))
        original.addLine(to: CGPoint(x: 20, y: 20))
        original.addLine(to: CGPoint(x: 10, y: 20))
        original.closeSubpath()
        let stroke = original.copy(strokingWithWidth: 2, lineCap: .butt,
                                   lineJoin: .round, miterLimit: 4)
        for (expansion, isPositive) in [(Float(1), true), (Float(-1), false)] {
            let value = try SampledMaskExpression(terms: [.init(path: source, mode: .add,
                                                               isInverted: false, expansion: expansion)])
            var budget = try GeometryBudget()
            let mesh = try RenderGeometrySource.maskExpression(value).prepare(
                precision: GeometryPrecision(transform: .identity), budget: &budget)
            var mismatches: [String] = []
            for yi in 0..<29 {
                for xi in 0..<29 {
                    let point = ScenePoint(x: Double(xi) * 0.5 + 7.137,
                                           y: Double(yi) * 0.5 + 7.293)
                    let cg = CGPoint(x: point.x, y: point.y)
                    let filled = original.contains(cg)
                    let stroked = stroke.contains(cg)
                    let expected = isPositive ? filled || stroked : filled && !stroked
                    let actual = GeometryTestSupport.coverage(mesh, at: point) > 0
                    if actual != expected, mismatches.count < 16 {
                        mismatches.append("(\(point.x),\(point.y)) actual=\(actual) original=\(filled) stroke=\(stroked)")
                    }
                }
            }
            #expect(mismatches.isEmpty, Comment(rawValue: mismatches.joined(separator: "; ")))
        }
    }

    /// 外轮廓与反向内孔的正扩张应缩孔、负扩张应扩大孔；逐点对照独立系统描边。
    @Test func signedExpansionPreservesNonzeroHole() throws {
        let source = try SourcePath(verbs: [.move, .line, .line, .line, .close,
                                            .move, .line, .line, .line, .close], points: [
            ScenePoint(x: 10, y: 10), ScenePoint(x: 40, y: 10),
            ScenePoint(x: 40, y: 40), ScenePoint(x: 10, y: 40),
            ScenePoint(x: 20, y: 20), ScenePoint(x: 20, y: 30),
            ScenePoint(x: 30, y: 30), ScenePoint(x: 30, y: 20)
        ])
        let original = CGMutablePath()
        original.move(to: CGPoint(x: 10, y: 10))
        original.addLine(to: CGPoint(x: 40, y: 10))
        original.addLine(to: CGPoint(x: 40, y: 40))
        original.addLine(to: CGPoint(x: 10, y: 40))
        original.closeSubpath()
        original.move(to: CGPoint(x: 20, y: 20))
        original.addLine(to: CGPoint(x: 20, y: 30))
        original.addLine(to: CGPoint(x: 30, y: 30))
        original.addLine(to: CGPoint(x: 30, y: 20))
        original.closeSubpath()
        let stroke = original.copy(strokingWithWidth: 4, lineCap: .butt,
                                   lineJoin: .round, miterLimit: 4)
        for (expansion, isPositive) in [(Float(2), true), (Float(-2), false)] {
            let value = try SampledMaskExpression(terms: [.init(path: source, mode: .add,
                                                               isInverted: false, expansion: expansion)])
            var budget = try GeometryBudget()
            let mesh = try RenderGeometrySource.maskExpression(value).prepare(
                precision: GeometryPrecision(transform: .identity), budget: &budget)
            var mismatches: [String] = []
            for yi in 0..<36 {
                for xi in 0..<36 {
                    // 系统路径包含边界点，但三角形覆盖辅助器仅计严格内部，错开对角线采样。
                    let point = ScenePoint(x: Double(xi) + 7.25, y: Double(yi) + 7.35)
                    let cg = CGPoint(x: point.x, y: point.y)
                    let originalFill = original.contains(cg)
                    let strokeFill = stroke.contains(cg)
                    let expected = isPositive ? originalFill || strokeFill : originalFill && !strokeFill
                    let actual = GeometryTestSupport.coverage(mesh, at: point) > 0
                    if actual != expected, mismatches.count < 12 {
                        mismatches.append("(\(point.x),\(point.y)) actual=\(actual) expected=\(expected)")
                    }
                }
            }
            #expect(mismatches.isEmpty, Comment(rawValue: mismatches.joined(separator: "; ")))
        }
    }

    /// 首轮廓开放、末轮廓闭合时仍是有效蒙版；开放段只按填充隐式闭合，描边保留Butt端点。
    @Test func openFirstContourAndClosedLastMatchSystemStroke() throws {
        let source = try SourcePath(verbs: [.move, .line, .line,
                                            .move, .line, .line, .line, .close], points: [
            ScenePoint(x: 10, y: 10), ScenePoint(x: 20, y: 10), ScenePoint(x: 15, y: 20),
            ScenePoint(x: 30, y: 10), ScenePoint(x: 40, y: 10),
            ScenePoint(x: 40, y: 20), ScenePoint(x: 30, y: 20)
        ])
        let system = CGMutablePath()
        system.move(to: CGPoint(x: 10, y: 10))
        system.addLine(to: CGPoint(x: 20, y: 10))
        system.addLine(to: CGPoint(x: 15, y: 20))
        system.move(to: CGPoint(x: 30, y: 10))
        system.addLine(to: CGPoint(x: 40, y: 10))
        system.addLine(to: CGPoint(x: 40, y: 20))
        system.addLine(to: CGPoint(x: 30, y: 20))
        system.closeSubpath()
        let points = [ScenePoint(x: 15.31, y: 13.47), ScenePoint(x: 15.31, y: 21.47),
                      ScenePoint(x: 11.31, y: 11.47), ScenePoint(x: 19.31, y: 11.47),
                      ScenePoint(x: 30.31, y: 15.47), ScenePoint(x: 35.31, y: 15.47),
                      ScenePoint(x: 40.31, y: 15.47), ScenePoint(x: 25.31, y: 15.47)]
        try compareExpansion(source, with: system, at: points, signedValues: [1, -1])
    }

    /// 凹角与自交路径的正并负差逐点对照系统非零填充和Butt/Round描边。
    @Test func concaveAndSelfCrossingContoursMatchSystemStroke() throws {
        let concavePoints = [ScenePoint(x: 10, y: 10), ScenePoint(x: 30, y: 10),
                             ScenePoint(x: 30, y: 15), ScenePoint(x: 15, y: 15),
                             ScenePoint(x: 15, y: 30), ScenePoint(x: 10, y: 30)]
        let bowtiePoints = [ScenePoint(x: 40, y: 10), ScenePoint(x: 60, y: 30),
                            ScenePoint(x: 40, y: 30), ScenePoint(x: 60, y: 10)]
        for (vertices, samples) in [
            (concavePoints, [ScenePoint(x: 11.37, y: 11.61), ScenePoint(x: 13.37, y: 13.61),
                             ScenePoint(x: 16.37, y: 16.61), ScenePoint(x: 20.37, y: 12.61),
                             ScenePoint(x: 20.37, y: 20.61), ScenePoint(x: 9.37, y: 20.61)]),
            (bowtiePoints, [ScenePoint(x: 50.37, y: 12.61), ScenePoint(x: 50.37, y: 27.61),
                            ScenePoint(x: 43.37, y: 20.61), ScenePoint(x: 57.37, y: 20.61),
                            ScenePoint(x: 50.37, y: 20.61), ScenePoint(x: 38.37, y: 20.61)])
        ] {
            let source = try SourcePath(verbs: [.move] + Array(repeating: .line,
                                                               count: vertices.count - 1) + [.close],
                                        points: vertices)
            let system = CGMutablePath()
            system.move(to: CGPoint(x: vertices[0].x, y: vertices[0].y))
            for point in vertices.dropFirst() { system.addLine(to: CGPoint(x: point.x, y: point.y)) }
            system.closeSubpath()
            try compareExpansion(source, with: system, at: samples, signedValues: [1, -1])
        }
    }

    /// 同一源的两块相隔3单位，正扩张2使描边在缝隙并合且无重复覆盖。
    @Test func positiveExpansionMergesSeparatedContours() throws {
        let source = try SourcePath(verbs: [.move, .line, .line, .line, .close,
                                            .move, .line, .line, .line, .close], points: [
            ScenePoint(x: 10, y: 10), ScenePoint(x: 20, y: 10),
            ScenePoint(x: 20, y: 20), ScenePoint(x: 10, y: 20),
            ScenePoint(x: 23, y: 10), ScenePoint(x: 33, y: 10),
            ScenePoint(x: 33, y: 20), ScenePoint(x: 23, y: 20)
        ])
        let system = CGMutablePath()
        for left in [10.0, 23.0] {
            system.addRect(CGRect(x: left, y: 10, width: 10, height: 10))
        }
        let points = [ScenePoint(x: 8.47, y: 15.31), ScenePoint(x: 15.47, y: 15.31),
                      ScenePoint(x: 21.47, y: 15.31), ScenePoint(x: 22.47, y: 15.31),
                      ScenePoint(x: 28.47, y: 15.31), ScenePoint(x: 34.47, y: 15.31),
                      ScenePoint(x: 36.47, y: 15.31)]
        try compareExpansion(source, with: system, at: points, signedValues: [2])
    }

    /// 非hairline负扩张吞掉全部有限面积时仍无法由空网格反推PathKit verb，须明确拒绝并不缓存。
    @Test func negativeExpansionEatingFillFailsExplicitly() throws {
        let source = try ShapePathFixtures.square(10)
        let value = try SampledMaskExpression(terms: [.init(path: source, mode: .add,
                                                           isInverted: false, expansion: -6)])
        var cache = try RenderGeometryCache()
        var budget = try GeometryBudget()
        #expect(throws: PAGError.unsupportedFeature("maskBooleanEmptyResult")) {
            try cache.mesh(for: .maskExpression(value), transform: .identity, budget: &budget)
        }
        #expect(cache.count == 0)
    }

    /// 输出轮廓的有限内存/工作预算和预取消必须传播，不能缓存半成品。
    @Test func expansionOutlineRespectsLimitsAndCancellation() async throws {
        let source = try ShapePathFixtures.square(10)
        let original = [GeometryTestSupport.rectangle(10, 10, 10, 10)]
        var bytes = try GeometryBudget(maximumBytes: 64)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try MaskExpansionGeometry.strokeContours(for: source, expansion: 2, original: original,
                                                      tolerance: 0.125, budget: &bytes)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var budget = try GeometryBudget()
            return try MaskExpansionGeometry.strokeContours(for: source, expansion: 2,
                                                            original: original, tolerance: 0.125,
                                                            budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        var tooWide = try GeometryBudget()
        #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeMagnitude")) {
            try MaskExpansionGeometry.strokeContours(for: source, expansion: 20_000_000,
                                                      original: original, tolerance: 0.125,
                                                      budget: &tooWide)
        }
    }

    /// PAG允许的非规范指令不能直接喂给较窄的StrokePath；转换无证据时应明确失败。
    @Test func unsupportedImplicitMoveSequenceDoesNotPublishMesh() throws {
        let path = try SourcePath(verbs: [.line, .line, .close], points: [
            ScenePoint(x: 10, y: 10), ScenePoint(x: 20, y: 20)
        ])
        let value = try SampledMaskExpression(terms: [.init(path: path, mode: .add,
                                                           isInverted: false, expansion: 1)])
        var cache = try RenderGeometryCache()
        var budget = try GeometryBudget()
        #expect(throws: PAGError.unsupportedFeature("maskExpansionPathSequence")) {
            try cache.mesh(for: .maskExpression(value), transform: .identity, budget: &budget)
        }
        #expect(cache.count == 0)
    }

    /// 仅Close的源项仍占首位；非零扩张不把PathKit的空Close误判为坏描边次序。
    @Test func closeOnlyExpandedFirstTermKeepsFollowingBooleanOrder() throws {
        let empty = try SourcePath(verbs: [.close, .close], points: [])
        let square = try ShapePathFixtures.square(10)
        let scenarios: [(SourceMaskMode, Bool, Bool)] = [(.add, false, false),
                                                        (.subtract, true, true)]
        for (mode, firstInverted, outside) in scenarios {
            let masks = [MaskTestSupport.mask(.init(constant: empty), inverted: firstInverted,
                                              expansion: .init(constant: 2)),
                         MaskTestSupport.mask(.init(constant: square), mode: mode)]
            var planBudget = FramePlanBudget(limit: 1_000_000)
            let sampled = try #require(try MaskPreparation.orderedPaths(masks, at: 0,
                                                                         budget: &planBudget))
            guard case .expression(let expression) = sampled else {
                Issue.record("空Close首项仍占据Boolean源顺序")
                return
            }
            #expect(expression.terms[0].path === empty)
            #expect(expression.isInverted == outside)
            var cache = try RenderGeometryCache()
            var geometryBudget = try GeometryBudget()
            let mesh = try cache.mesh(for: .maskExpression(expression), transform: .identity,
                                      budget: &geometryBudget)
            #expect(GeometryTestSupport.area(mesh) == 100)
            #expect(GeometryTestSupport.coverage(mesh, at: .init(x: 14.31, y: 15.73)) == 1)
        }
    }

    /// 用独立CoreGraphics填充/描边金值检查少量远离边界的点，且网格不得重叠覆盖。
    private func compareExpansion(_ source: SourcePath, with system: CGPath,
                                  at points: [ScenePoint], signedValues: [Float]) throws {
        for expansion in signedValues {
            let value = try SampledMaskExpression(terms: [.init(path: source, mode: .add,
                                                               isInverted: false, expansion: expansion)])
            var budget = try GeometryBudget()
            let mesh = try RenderGeometrySource.maskExpression(value).prepare(
                precision: GeometryPrecision(transform: .identity), budget: &budget)
            let stroke = system.copy(strokingWithWidth: CGFloat(abs(expansion) * 2),
                                     lineCap: .butt, lineJoin: .round, miterLimit: 4)
            for point in points {
                let cg = CGPoint(x: point.x, y: point.y)
                let original = system.contains(cg)
                let stroked = stroke.contains(cg)
                let expected = expansion > 0 ? original || stroked : original && !stroked
                let coverage = GeometryTestSupport.coverage(mesh, at: point)
                #expect(coverage <= 1)
                #expect((coverage > 0) == expected,
                        "扩张\(expansion)点\(point)实测\(coverage)原填充\(original)描边\(stroked)")
            }
        }
    }
}
