import Testing
@testable import pag_swift

/// Ellipse固定Conic拓扑、负尺寸绕序、Fill精度及预算；期望来自源码点索引，不借用平台路径。
struct EllipseGeneratorTests {
    /// 两个方向都从顶部开始，真实Conic控制点及权重进入Stroke，不换成矩形oval的右侧起点。
    @Test(arguments: [false, true])
    func sourceConicsPreserveTopStart(_ reversed: Bool) throws {
        let contour = try EllipseContour.make(ShapeGeneratorFixtures.ellipse(reversed: reversed), at: 0, matrix: .identity)
        let path = try ShapeGeneratorFixtures.centerline([.ellipse(contour)])
        let conic = StrokePathVerb.conic(weight: Float(0.707106781))
        #expect(path.verbs == [.move, conic, conic, conic, conic, .close])
        let clockwise = [p(0, -5), p(10, -5), p(10, 0), p(10, 5), p(0, 5), p(-10, 5), p(-10, 0), p(-10, -5), p(0, -5)]
        let counter = [p(0, -5), p(-10, -5), p(-10, 0), p(-10, 5), p(0, 5), p(10, 5), p(10, 0), p(10, -5), p(0, -5)]
        #expect(path.points == (reversed ? counter : clockwise))
    }

    /// 负宽/高不排序或翻转reversed，零轴保留6verb/9point供描边消费者处理。
    @Test(arguments: [-20.0, 0, 20], [-10.0, 0, 10])
    func signedAndZeroSizesRemainUnsorted(_ width: Double, _ height: Double) throws {
        let source = ShapeGeneratorFixtures.ellipse(size: .init(constant: p(width, height)))
        let contour = try EllipseContour.make(source, at: 0, matrix: .identity)
        #expect(contour.left == Float(-width / 2) && contour.right == Float(width / 2))
        let path = try ShapeGeneratorFixtures.centerline([.ellipse(contour)])
        #expect(path.verbs.count == 6 && path.points.count == 9)
        #expect(path.points[0] == p(0, -height / 2) && path.points[2] == p(width / 2, 0))
        #expect(path.points[4] == p(0, height / 2) && path.points[6] == p(-width / 2, 0))
    }

    /// 组矩阵之后才判断Fill覆盖；反向负轴椭圆与正轴叠加产生孔洞，零轴无伪填充。
    @Test func compoundWindingAndDegenerateFill() throws {
        let outer = try EllipseContour.make(ShapeGeneratorFixtures.ellipse(size: .init(constant: p(40, 40))), at: 0, matrix: .identity)
        let hole = try EllipseContour.make(ShapeGeneratorFixtures.ellipse(size: .init(constant: p(-20, 20))), at: 0, matrix: .identity)
        let mesh = try ShapeGeneratorFixtures.mesh(ShapeGeometry(contours: [.ellipse(outer), .ellipse(hole)]))
        #expect(GeometryTestSupport.coverage(mesh, at: p(0.1, 0.2)) == 0)
        #expect(GeometryTestSupport.coverage(mesh, at: p(15, 0.2)) == 1)
        #expect(abs(GeometryTestSupport.area(mesh) - 300 * Double.pi) < 5)
        let zero = try EllipseContour.make(ShapeGeneratorFixtures.ellipse(size: .init(constant: p(0, 20))), at: 0, matrix: .identity)
        #expect(try ShapeGeneratorFixtures.mesh(ShapeGeometry(contours: [.ellipse(zero)])).vertices.isEmpty)
    }

    /// 普通Fill不继承描边2^24坐标限制；大原点的Float MakeXYWH舍入与组矩阵仍只应用一次。
    @Test func floatBoundsAndFillMagnitudeAreIndependentOfStroke() throws {
        let source = ShapeGeneratorFixtures.ellipse(size: .init(constant: p(3, 10)),
            position: .init(constant: p(16_777_216, 0)))
        let matrix = try SceneAffine.translation(x: -16_777_216, y: 0)
        let contour = try EllipseContour.make(source, at: 0, matrix: matrix)
        #expect(contour.left == 16_777_214 && contour.right == 16_777_216)
        let mesh = try ShapeGeneratorFixtures.mesh(ShapeGeometry(contours: [.ellipse(contour)]))
        #expect(GeometryTestSupport.coverage(mesh, at: p(-1, 0.1)) == 1)
        #expect(GeometryTestSupport.coverage(mesh, at: p(1, 0.1)) == 0)
        let large = try EllipseContour.make(ShapeGeneratorFixtures.ellipse(size: .init(constant: p(32, 16)),
            position: .init(constant: p(33_554_432, 0))), at: 0, matrix: .identity)
        #expect(try ShapeGeneratorFixtures.mesh(ShapeGeometry(contours: [.ellipse(large)])).vertices.isEmpty == false)
        #expect(throws: PAGError.self) { try ShapeGeneratorFixtures.centerline([.ellipse(large)]) }
    }

    /// 非均匀组缩放后密采样原rational曲线，到输出折线的距离仍落在整层容差内。
    @Test func twoApproximationStagesShareOneErrorBudget() throws {
        let matrix = try SceneAffine.scale(x: 7.3, y: 1.1).following(.translation(x: 13, y: -7))
        let contour = try EllipseContour.make(ShapeGeneratorFixtures.ellipse(), at: 0, matrix: matrix)
        var budget = try GeometryBudget()
        let paths = try PathFlattening.shape(ShapeGeometry(contours: [.ellipse(contour)]), tolerance: 0.125, budget: &budget)
        let boundary = try #require(paths.first)
        for conic in try contour.conics(budget: &budget) {
            for sample in 0...128 {
                let t = Double(sample) / 128, u = 1 - t, w = conic.weights[1]
                let coefficients = [u * u, 2 * u * t * w, t * t]
                let denominator = coefficients.reduce(0, +)
                let local = p(zip(coefficients, conic.points).reduce(0) { $0 + $1.0 * $1.1.x } / denominator,
                              zip(coefficients, conic.points).reduce(0) { $0 + $1.0 * $1.1.y } / denominator)
                let point = try matrix.applying(to: local)
                let distance = try boundary.indices.map {
                    try GeometryMath.distance(point, to: boundary[$0], boundary[($0 + 1) % boundary.count])
                }.min()
                #expect(try #require(distance) <= 0.125)
            }
        }
    }

    /// 新生成器的组矩阵与逆paint仍是两次Float舍入，不合并成恒等Double矩阵。
    @Test func strokeKeepsSeparateForwardAndInverseStages() throws {
        let matrix = try SceneAffine.translation(x: 16_777_216, y: 0)
        let ellipse = try EllipseContour.make(ShapeGeneratorFixtures.ellipse(size: .init(constant: p(6, 10))), at: 0, matrix: matrix)
        let ellipsePath = try ShapeGeneratorFixtures.centerline([.ellipse(ellipse)], paint: matrix)
        #expect(ellipsePath.points[0] == p(0, -5) && ellipsePath.points[2] == p(4, 0))
        let polygon = try PolyStarContour.make(ShapeGeneratorFixtures.polyStar(kind: .polygon,
            points: .init(constant: 3), outerRadius: .init(constant: 3)), at: 0, matrix: matrix)
        let polygonPath = try ShapeGeneratorFixtures.centerline([.polyStar(polygon)], paint: matrix)
        #expect(polygonPath.points[0] == p(4, 0))
    }

    /// 固定临时Conic也计费；工作不足、极小容差、源Float溢出和预取消均整体失败。
    @Test func limitsPrecisionAndCancellationFail() async throws {
        let contour = try EllipseContour.make(ShapeGeneratorFixtures.ellipse(), at: 0, matrix: .identity)
        var tiny = try GeometryBudget(maximumBytes: 2047)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) { try contour.conics(budget: &tiny) }
        var work = try GeometryBudget(maximumWork: 31)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) { try contour.conics(budget: &work) }
        var precision = try GeometryBudget()
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try PathFlattening.ellipse(contour, tolerance: .leastNonzeroMagnitude, budget: &precision)
        }
        let overflow = ShapeGeneratorFixtures.ellipse(size: .init(constant: p(Double.greatestFiniteMagnitude, 1)))
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try EllipseContour.make(overflow, at: 0, matrix: .identity)
        }
        await #expect(throws: CancellationError.self) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.cancelAll()
                group.addTask {
                    var budget = try GeometryBudget()
                    _ = try contour.conics(budget: &budget)
                }
                for try await _ in group {}
            }
        }
    }

    /// 以场景坐标书写独立期望点，避免生产索引算法同时生成测试期望。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }
}
