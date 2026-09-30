import Testing
@testable import pag_swift

/// 直接核验边界点归属和顺序，防止相同bounds掩盖NearlyLine/Nearly180与miter修改错误。
struct StrokeLineJoinTests {
    /// 90°miter覆盖已有末点，bevel追加角点；内侧两种情况均经过pivot。
    @Test func rightAngleChangesLastPointRatherThanAddingSpike() throws {
        for (join, limit, expected): (SourceLineJoin, Float, [ScenePoint]) in [
            (.miter, 2, [p(12, -2)]), (.miter, 1.25, [p(10, -2), p(12, 0)]),
            (.bevel, 4, [p(10, -2), p(12, 0)])
        ] {
            let pair = try joined(before: SIMD2(0, -1), after: SIMD2(1, 0), join: join, limit: limit)
            #expect(pair.0.points == expected)
            #expect(pair.1.points == [p(10, 2), p(10, 0), p(8, 0)])
        }
    }

    /// 180°miter在交换前bevel；普通bevel反而交换，必须检查两条边的真实点序列。
    @Test func oppositeMiterDoesNotSwapBoundaries() throws {
        let miter = try joined(before: SIMD2(0, -1), after: SIMD2(0, 1), join: .miter)
        #expect(miter.0.points == [p(10, -2), p(10, 2)])
        #expect(miter.1.points == [p(10, 2), p(10, 0), p(10, -2)])
        let bevel = try joined(before: SIMD2(0, -1), after: SIMD2(0, 1), join: .bevel)
        #expect(bevel.0.points == [p(10, -2), p(10, 0), p(10, 2)])
        #expect(bevel.1.points == [p(10, 2), p(10, -2)])
    }

    /// Float dot门槛等值省略整个Round/Miter接角，下一可表示值才进入接角；镜像不改变门槛。
    @Test func nearlyLineThresholdIsInclusiveAndSymmetric() throws {
        let threshold: Float = 1 - 1.0 / 4096
        for dot in [threshold, threshold.nextDown] {
            let y = (1 - dot * dot).squareRoot()
            for sign: Float in [-1, 1] {
                for join in [SourceLineJoin.miter, .round] {
                    let pair = try joined(before: SIMD2(1, 0), after: SIMD2(dot, sign * y), join: join)
                    let count = pair.0.verbs.count + pair.1.verbs.count
                    #expect((count == 4) == (dot == threshold))
                }
            }
        }
    }

    /// 90°两侧不对称的Float余弧省略遵守源码；禁止总补齐到目标法线端点。
    @Test func roundRemainderKeepsSourceQuadrantEndpoint() throws {
        for x: Float in [-1.0 / 8192, 1.0 / 8192] {
            var outputBudget = try GeometryBudget()
            let output = try StrokePathOutput(budget: &outputBudget, limits: .standard)
            let boundary = StrokeLineBoundary()
            try boundary.move(to: SIMD2(4096, 0), output: output)
            let count = try StrokeLineJoin.arc(before: SIMD2(1, 0), after: SIMD2(x, 1), clockwise: true,
                                              pivot: .zero, radius: 4096, boundary: boundary, output: output)
            #expect(count == 1)
            #expect(boundary.last == SIMD2(x < 0 ? 0 : 0.5, 4096))
        }
    }

    /// conic真实起点沿用已有边界末点，即使和理论法线点不同，也不能偷偷Move或焊接。
    @Test func roundArcPreservesExistingBoundaryStart() throws {
        var outputBudget = try GeometryBudget()
        let output = try StrokePathOutput(budget: &outputBudget, limits: .standard)
        let boundary = StrokeLineBoundary()
        try boundary.move(to: SIMD2(2.25, 0), output: output)
        #expect(try StrokeLineJoin.arc(before: SIMD2(1, 0), after: SIMD2(0, 1), clockwise: true,
                                      pivot: .zero, radius: 2, boundary: boundary, output: output) == 1)
        try boundary.emit(reversed: false, restoration: .identity, tolerance: 0.001, output: output)
        let result = try output.finish()
        #expect(result.points.first == p(2.25, 0))
        #expect(result.points.last == p(0, 2))
        #expect(result.verbs.filter { $0 == .move }.count == 1)
    }

    /// Close零范围检查包含控制点及被setLastPt替换的末点，首末相等不代表整条边界零长。
    @Test func boundaryExtentIncludesControlsAndReplacedEndpoints() throws {
        var outputBudget = try GeometryBudget()
        let output = try StrokePathOutput(budget: &outputBudget, limits: .standard)
        let boundary = StrokeLineBoundary()
        try boundary.move(to: .zero, output: output)
        try boundary.append(to: SIMD2(1, 0), output: output)
        #expect(try boundary.isZeroLength(output: output) == false)
        try boundary.replaceLast(with: .zero, output: output)
        #expect(try boundary.isZeroLength(output: output))
        try boundary.append(to: .zero, control: SIMD2(0, 1), weight: 0.75, output: output)
        #expect(try boundary.isZeroLength(output: output) == false)
    }

    /// 从两条仅Move边界开始执行真实join，保留原/内归属以便独立检查。
    private func joined(before: SIMD2<Float>, after: SIMD2<Float>, join: SourceLineJoin,
                        limit: Float = 4) throws -> (SourcePath, SourcePath) {
        var outputBudget = try GeometryBudget()
        let output = try StrokePathOutput(budget: &outputBudget, limits: .standard)
        let outer = StrokeLineBoundary(), inner = StrokeLineBoundary(), pivot = SIMD2<Float>(10, 0)
        try outer.move(to: pivot + before * 2, output: output)
        try inner.move(to: pivot - before * 2, output: output)
        try StrokeLineJoin.append(before: before, after: after, pivot: pivot, radius: 2,
                                  join: join, miterLimit: limit, outer: outer, inner: inner, output: output)
        var aBudget = output.budget
        let a = try StrokePathOutput(budget: &aBudget, limits: .standard)
        try outer.emit(reversed: false, restoration: .identity, tolerance: 0.001, output: a)
        var bBudget = a.budget
        let b = try StrokePathOutput(budget: &bBudget, limits: .standard)
        try inner.emit(reversed: false, restoration: .identity, tolerance: 0.001, output: b)
        return try (a.finish(), b.finish())
    }

    /// 点期望来自源码几何手算，不复用生产坐标转换。
    private func p(_ x: Double, _ y: Double) -> ScenePoint { ScenePoint(x: x, y: y) }
}
