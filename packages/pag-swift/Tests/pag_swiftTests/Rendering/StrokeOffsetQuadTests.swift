import Testing
@testable import pag_swift

/// 偏移候选的独立射线与误差谓词；明确区分源退化分支和最终几何失败。
struct StrokeOffsetQuadTests {
    /// 平行同向与反向均为Degenerate，但后者禁止已找到切线后的直接Line回退。
    @Test func parallelRaysRetainOppositeFlag() throws {
        var budget = try GeometryBudget()
        var same = quad(.zero, SIMD2(1, 0), SIMD2(4, 0), SIMD2(5, 0))
        #expect(try same.intersection(needsControl: true, budget: &budget) == .degenerate)
        #expect(same.oppositeTangents == false)
        var opposite = quad(.zero, SIMD2(1, 0), SIMD2(4, 0), SIMD2(3, 0))
        #expect(try opposite.intersection(needsControl: false, budget: &budget) == .degenerate)
        #expect(opposite.oppositeTangents)
        var overflow = quad(.zero, SIMD2(Float.greatestFiniteMagnitude, 0), SIMD2(1, 1), SIMD2(0, Float.greatestFiniteMagnitude))
        #expect(try overflow.intersection(needsControl: true, budget: &budget) == .degenerate)
    }

    /// 合法交点只在请求时填控制点；外侧交点按两次pt_to_line的含等号阈值分类。
    @Test func intersectionsPreserveControlModeAndOutsideThreshold() throws {
        var budget = try GeometryBudget()
        var valid = quad(.zero, SIMD2(1, 1), SIMD2(4, 0), SIMD2(5, -1))
        #expect(try valid.intersection(needsControl: false, budget: &budget) == .quadratic)
        #expect(valid.control == .zero)
        #expect(try valid.intersection(needsControl: true, budget: &budget) == .quadratic)
        #expect(valid.control == SIMD2(2, 2))
        for y: Float in [0.25, Float(0.25).nextUp, 2] {
            var outside = quad(.zero, SIMD2(1, 0), SIMD2(0, y), SIMD2(1, y + 1))
            #expect(try outside.intersection(needsControl: true, budget: &budget) == (y == 0.25 ? .degenerate : .split))
        }
    }

    /// 零弦和段外投影回落lineStart，而不是抛NaN或改为最近端点。
    @Test func sourceDistanceFallbackAndStrictThreshold() {
        #expect(StrokeOffsetQuad.distanceSquared(SIMD2(3, 4), from: .zero, to: .zero) == 25)
        #expect(StrokeOffsetQuad.distanceSquared(SIMD2(3, 0), from: .zero, to: SIMD2(1, 0)) == 9)
        let distance = StrokeOffsetQuad.distanceSquared(SIMD2(1, 0.25), from: .zero, to: SIMD2(2, 0))
        #expect(distance == 0.0625)
        #expect((distance < 0.0625) == false)
        #expect(StrokeOffsetQuad.within(.zero, SIMD2(0, 0.25), limit: 0.25))
    }

    /// 中点距离0.25可接受，超过则须继续射线检查；尖角即使中点重合也必须拒绝。
    @Test func midpointToleranceAndSharpAngleAreIndependent() throws {
        var budget = try GeometryBudget()
        var smooth = quad(.zero, SIMD2(1, 1), SIMD2(4, 0), SIMD2(5, -1))
        #expect(try smooth.intersection(needsControl: true, budget: &budget) == .quadratic)
        for y: Float in [1.25, Float(1.25).nextUp] {
            let point = SIMD2<Float>(2, y)
            let ray = StrokeOffsetRay(curve: point, offset: point, tangent: point)
            #expect(try smooth.accepts(ray, budget: &budget) == (y == 1.25))
        }
        var sharp = quad(.zero, SIMD2(1, 1), SIMD2(4, 0), SIMD2(3, -3))
        #expect(try sharp.intersection(needsControl: true, budget: &budget) == .quadratic)
        #expect(sharp.control == SIMD2(6, 6))
        let point = SIMD2<Float>(4, 3)
        #expect(try sharp.accepts(StrokeOffsetRay(curve: point, offset: point, tangent: point), budget: &budget) == false)
    }

    /// 手工射线只用于独立谓词验证，不声称是任何Cubic的完整描边结果。
    private func quad(_ start: SIMD2<Float>, _ startTangent: SIMD2<Float>, _ end: SIMD2<Float>,
                      _ endTangent: SIMD2<Float>) -> StrokeOffsetQuad {
        StrokeOffsetQuad(start: 0, end: 1,
            first: StrokeOffsetRay(curve: start, offset: start, tangent: startTangent),
            last: StrokeOffsetRay(curve: end, offset: end, tangent: endTangent))
    }
}
