import Foundation
import Testing
@testable import pag_swift

/// 裁剪原生曲线进入Fill与Stroke的语义验证；像素和真实drawable留到后续显示门禁。
struct TrimGeometryTests {
    /// 半个方形轮廓填充时隐式封成三角形，描边仍是开放L形，不能把Fill闭合写回共享路径。
    @Test func fillClosureDoesNotChangeStrokeTopology() throws {
        let source = try ShapePathFixtures.square(10)
        let batch = try TrimBatchFixtures.batch([.path(source, matrix: .identity)], TrimBatchFixtures.source(0, 0.5))
        let fill = try ShapeGeometry(contours: batch.outputs)
        let mesh = try ShapeGeneratorFixtures.mesh(fill)
        #expect(abs(GeometryTestSupport.area(mesh) - 50) < 0.0001)
        let path = try ShapeGeneratorFixtures.centerline(batch.outputs)
        #expect(path.verbs == [.move, .line, .line] && !path.verbs.contains(.close))
        #expect(path.points == [ScenePoint(x: 10, y: 10), ScenePoint(x: 20, y: 10), ScenePoint(x: 20, y: 20)])
        let stroke = try ShapeGeometry(contours: batch.outputs,
            stroke: ShapeStroke(style: StrokeGeometryTestSupport.style(width: 2), matrix: .identity))
        #expect(abs(GeometryTestSupport.area(try ShapeGeneratorFixtures.mesh(stroke)) - 40) < 0.0001)
        #expect(try TrimBatchFixtures.path(batch.outputs[0]).path.verbs == path.verbs)
    }

    /// 椭圆与圆角矩形裁剪保留Conic直到最终消费者；Fill面积与独立半圆公式相符。
    @Test func conicsRemainNativeUntilFinalFill() throws {
        let source = ShapeGeneratorFixtures.ellipse(size: .init(constant: ScenePoint(x: 20, y: 20)))
        let ellipse = try EllipseContour.make(source, at: 0, matrix: .identity)
        let batch = try TrimBatchFixtures.batch([.ellipse(ellipse)], TrimBatchFixtures.source(0, 0.5))
        let path = try TrimBatchFixtures.path(batch.outputs[0]).path
        #expect(path.verbs.contains { if case .conic = $0 { true } else { false } })
        #expect(try ShapeGeneratorFixtures.centerline(batch.outputs).verbs == path.verbs)
        let fill = try ShapeGeometry(contours: batch.outputs)
        let mesh = try ShapeGeneratorFixtures.mesh(fill)
        #expect(abs(GeometryTestSupport.area(mesh) - Double.pi * 50) < 2)
        let rectangle = try RoundedRectangleContour.make(size: ScenePoint(x: 20, y: 10), position: .zero,
                                                         roundness: 3, reversed: false, matrix: .identity)
        let rounded = try TrimBatchFixtures.batch([.rectangle(rectangle)], TrimBatchFixtures.source(0.1, 0.9))
        #expect(try TrimBatchFixtures.path(rounded.outputs[0]).path.verbs.contains { if case .conic = $0 { true } else { false } })
        #expect(try !ShapeGeneratorFixtures.mesh(ShapeGeometry(contours: rounded.outputs)).vertices.isEmpty)
    }

    /// PolyStar沿原生成器展开再裁剪，Quad的填充面积来自解析积分，不由同一flatten结果生成期望。
    @Test func starAndQuadraticUseGeneralCurveConsumers() throws {
        let star = try PolyStarContour.make(ShapeGeneratorFixtures.polyStar(points: .init(constant: 5),
            innerRadius: .init(constant: 5), outerRadius: .init(constant: 10)), at: 0, matrix: .identity)
        let batch = try TrimBatchFixtures.batch([.polyStar(star)], TrimBatchFixtures.source(0, 0.75))
        #expect(try !ShapeGeneratorFixtures.mesh(ShapeGeometry(contours: batch.outputs)).vertices.isEmpty)
        var budget = try GeometryBudget()
        let quad = try StrokePath(verbs: [.move, .quad], points: [.zero, ScenePoint(x: 10, y: 20), ScenePoint(x: 20, y: 0)], budget: &budget)
        let contour = ShapeContour.trimmed(try PreparedTrimPath(quad))
        let mesh = try ShapeGeneratorFixtures.mesh(ShapeGeometry(contours: [contour]))
        #expect(abs(GeometryTestSupport.area(mesh) - 400.0 / 3) < 2)
        #expect(try ShapeGeneratorFixtures.centerline([contour]).verbs == [.move, .quad])
    }

    /// 普通Fill可接受超出描边坐标策略的Trim输出；Stroke仍在自己入口拒绝，不扩大旧限额。
    @Test func generalFillDoesNotInheritStrokeAdmission() throws {
        let origin = 33_554_432.0
        let path = try SourcePath(verbs: [.move, .line, .line, .line, .close], points: [
            ScenePoint(x: origin, y: 0), ScenePoint(x: origin + 16, y: 0),
            ScenePoint(x: origin + 16, y: 16), ScenePoint(x: origin, y: 16)])
        let batch = try TrimBatchFixtures.batch([.path(path, matrix: .identity)], TrimBatchFixtures.source(0, 0.5))
        let fill = try ShapeGeometry(contours: batch.outputs)
        #expect(abs(GeometryTestSupport.area(try ShapeGeneratorFixtures.mesh(fill)) - 128) < 0.001)
        #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeMagnitude")) {
            try ShapeGeneratorFixtures.centerline(batch.outputs)
        }
        var cache = try RenderGeometryCache()
        var cold = try GeometryBudget()
        let first = try cache.mesh(for: .shape(fill), transform: .identity, budget: &cold)
        var warm = try GeometryBudget(maximumWork: 1)
        #expect(try cache.mesh(for: .shape(fill), transform: .identity, budget: &warm) === first)
    }
}
