import Testing
@testable import pag_swift

/// Quad/Conic单侧偏移的独立源码数值期望；通过最终出口读取Q/Line，不据此宣称完整描边已接通。
struct StrokeQuadraticOffsetTests {
    /// 单个二次拱形成一个偏移Q，保留源Float控制点的一ULP次序。
    @Test func quadraticArchUsesIndependentFloatControl() throws {
        let curve = try StrokeQuadCurve(start: .zero, control: SIMD2(1, 1), end: SIMD2(2, 0))
        let path = try outline(curve, radius: 1, side: 1)
        try expectSegments(path, start: bits(0x3F3504F3, 0xBF3504F3),
                           controls: [bits(0x3F800000, 0xBED413CD)], ends: [bits(0x3FA57D86, 0xBF3504F3)])
    }

    /// 单位四分圆半宽1时外侧是一条手算Q，内侧收缩到同一中心并成为零Line。
    @Test func quarterCircleHasExactOuterAndCollapsedInner() throws {
        let curve = try quarter()
        let outer = try outline(curve, radius: 1, side: 1)
        let inner = try outline(curve, radius: 1, side: -1)
        try expectSegments(outer, start: SIMD2(2, 0), controls: [SIMD2(2, 2)], ends: [SIMD2(0, 2)])
        try expectSegments(inner, start: .zero, controls: [nil], ends: [.zero])
    }

    /// 宽quarter两侧都真实细分成两个Q，独立期望保留正侧不对称与负侧第一控制点的一ULP差。
    @Test func wideConicSubdividesUsingGlobalSamples() throws {
        let curve = try quarter()
        let outer = try outline(curve, radius: 8, side: 1)
        let inner = try outline(curve, radius: 8, side: -1)
        try expectSegments(outer, start: SIMD2(9, 0),
            controls: [bits(0x41100000, 0x406E9643), bits(0x406E9644, 0x41100000)],
            ends: [bits(0x40CBA591, 0x40CBA591), SIMD2(0, 9)])
        try expectSegments(inner, start: SIMD2(-7, 0),
            controls: [bits(0xC0DFFFFF, 0xC0399154), bits(0xC0399154, 0xC0E00000)],
            ends: [bits(0xC09E6455, 0xC09E6455), SIMD2(0, -7)])
    }

    /// 宽Quad的二次接受经过射线交点误差分支，不能只实现中点欧氏距离快路。
    @Test func wideQuadraticUsesRayIntersectionAcceptance() throws {
        let curve = try StrokeQuadCurve(start: .zero, control: SIMD2(2, 2), end: SIMD2(4, 0))
        let path = try outline(curve, radius: 8, side: 1)
        try expectSegments(path, start: bits(0x40B504F3, 0xC0B504F3),
            controls: [bits(0x408A09E6, 0xC0E00000), bits(0xBEA09E60, 0xC0E00001)],
            ends: [bits(0x40000000, 0xC0E00000), bits(0xBFD413CC, 0xC0B504F3)])
    }

    /// 真正非线性曲线也可因绝对切线点舍入成为反向退化；两类都必须直接接受Line。
    @Test func oppositeTangentsAreAcceptedWithoutCubicRejection() throws {
        let start = SIMD2<Float>(8_388_608, 0), control = SIMD2<Float>(8_389_632, 2048), end = SIMD2<Float>(8_390_656, 0)
        let quad = try StrokeQuadCurve(start: start, control: control, end: end)
        let conic = try StrokeConicCurve(start: start, control: control, end: end, weight: 0.5)
        var budget = try GeometryBudget()
        guard case .curve = try StrokeQuadraticAnalysis.reduction(of: quad, budget: &budget),
              case .curve = try StrokeQuadraticAnalysis.reduction(of: conic, budget: &budget) else {
            Issue.record("夹具必须是真正曲线，不能先降为Line")
            return
        }
        let first = try StrokeQuadraticSampling.ray(quad, at: 0, radius: 1, side: 1, budget: &budget)
        let last = try StrokeQuadraticSampling.ray(quad, at: 1, radius: 1, side: 1, budget: &budget)
        var candidate = StrokeOffsetQuad(start: 0, end: 1, first: first, last: last)
        #expect(try candidate.intersection(needsControl: true, budget: &budget) == .degenerate)
        #expect(candidate.oppositeTangents)
        for path in [try outline(quad, radius: 1, side: 1), try outline(conic, radius: 1, side: 1)] {
            try expectSegments(path, start: bits(0x4B000001, 0xBEE4F92E), controls: [nil], ends: [bits(0x4B0007FF, 0xBEE4F92E)])
        }
    }

    /// 相邻全局参数中点舍为1仍可能接受Q；不能用停滞判定替代真实求交和接受谓词。
    @Test func stagnantMidpointCanStillProduceQuadratic() throws {
        let path = try outline(quarter(), radius: 1, side: 1, start: Float(1).nextDown)
        let first = bits(0x347504F4, 0x40000000)
        try expectSegments(path, start: first, controls: [first], ends: [SIMD2(0, 2)])
    }

    /// 同一停滞区间放大半宽后持续Split，必须受32层预算失败，不可静默改为父终点Line。
    @Test func stagnantSubdivisionReachesBudgetFailure() throws {
        #expect(throws: PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")) {
            try outline(quarter(), radius: 2_097_152, side: 1, start: Float(1).nextDown,
                        budget: GeometryBudget(maximumDepth: 32))
        }
    }

    /// 中点舍到start时左子为零Line、右子重复原区间；元素限额和深度限额夹出32个真实临时Line。
    @Test func rightStagnationRetainsCollapsedLeftLeavesUntilFailure() throws {
        for value: (Int, PAGError) in [
            (31, .resourceLimitExceeded("maximumStrokeOutputElements")),
            (32, .resourceLimitExceeded("maximumGeometryCurveDepth"))
        ] {
            // 两次都通过完整候选拥有者验证失败，不为了检查前缀而发布残缺SourcePath。
            #expect(throws: value.1) {
                try outline(quarter(), radius: 2_097_152, side: 1,
                            start: Float(bitPattern: 0x3EBFFF04), end: Float(bitPattern: 0x3EBFFF05),
                            budget: GeometryBudget(maximumDepth: 32),
                            limits: StrokeBackendLimits(maximumOutputElements: value.0))
            }
        }
    }

    /// 叶接受在深度检查之前；零深度可输出正常quarter，但不能接受确实需要分裂的宽停滞区间。
    @Test func acceptedLeavesDoNotRequireRecursionAllowance() throws {
        let path = try outline(quarter(), radius: 1, side: 1, budget: GeometryBudget(maximumDepth: 0))
        try expectSegments(path, start: SIMD2(2, 0), controls: [SIMD2(2, 2)], ends: [SIMD2(0, 2)])
        #expect(throws: PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")) {
            try outline(quarter(), radius: 2_097_152, side: 1, start: Float(1).nextDown,
                        budget: GeometryBudget(maximumDepth: 0))
        }
    }

    /// 外部区间必须非空且位于0...1，两类入口统一拒绝；内部停滞许可不能泄漏到根接口。
    @Test func invalidRootIntervalsFailBeforeSampling() throws {
        let quad = try StrokeQuadCurve(start: .zero, control: SIMD2(1, 1), end: SIMD2(2, 0))
        let conic = try quarter()
        for range: (Float, Float) in [(0, 0), (1, 1), (0.8, 0.2), (-1, 1), (0, 2), (.nan, 1), (0, .infinity)] {
            var budget = try GeometryBudget()
            let output = try StrokePathOutput(budget: &budget, limits: .standard)
            let boundary = StrokeLineBoundary()
            try boundary.move(to: .zero, output: output)
            #expect(throws: PAGError.invalidArgument("strokeQuadraticInterval")) {
                try StrokeQuadraticOffset.append(quad, radius: 1, side: 1, start: range.0, end: range.1, to: boundary, output: output)
            }
            #expect(throws: PAGError.invalidArgument("strokeQuadraticInterval")) {
                try StrokeQuadraticOffset.append(conic, radius: 1, side: 1, start: range.0, end: range.1, to: boundary, output: output)
            }
        }
    }

    /// 以基础sampler建立实际起点，完整偏移和出口均成功才返回路径。
    private func outline(_ curve: StrokeQuadCurve, radius: Float, side: Float,
                         start: Float = 0, end: Float = 1, budget: GeometryBudget? = nil) throws -> SourcePath {
        var budget = try budget ?? GeometryBudget()
        let output = try StrokePathOutput(budget: &budget, limits: .standard)
        let boundary = StrokeLineBoundary()
        let first = try StrokeQuadraticSampling.ray(curve, at: start, radius: radius, side: side, budget: &output.budget)
        try boundary.move(to: first.offset, output: output)
        try StrokeQuadraticOffset.append(curve, radius: radius, side: side, start: start, end: end, to: boundary, output: output)
        try boundary.emit(reversed: false, restoration: .identity, tolerance: 0.001, output: output)
        return try output.finish()
    }

    /// Conic测试同样通过真实输出器持有完整候选，失败不返回部分路径。
    private func outline(_ curve: StrokeConicCurve, radius: Float, side: Float,
                         start: Float = 0, end: Float = 1, budget: GeometryBudget? = nil,
                         limits: StrokeBackendLimits = .standard) throws -> SourcePath {
        var budget = try budget ?? GeometryBudget()
        let output = try StrokePathOutput(budget: &budget, limits: limits)
        let boundary = StrokeLineBoundary()
        let first = try StrokeQuadraticSampling.ray(curve, at: start, radius: radius, side: side, budget: &output.budget)
        try boundary.move(to: first.offset, output: output)
        try StrokeQuadraticOffset.append(curve, radius: radius, side: side, start: start, end: end, to: boundary, output: output)
        try boundary.emit(reversed: false, restoration: .identity, tolerance: 0.001, output: output)
        return try output.finish()
    }

    /// 用解析2/3关系把独立Q控制点转换为期望三次点；不调用生产转换器构造答案。
    private func expectSegments(_ path: SourcePath, start: SIMD2<Float>, controls: [SIMD2<Float>?], ends: [SIMD2<Float>]) throws {
        #expect(path.verbs == [.move] + controls.map { $0 == nil ? .line : .cubic } + [.close])
        try #require(path.points.count == 1 + controls.reduce(0) { $0 + ($1 == nil ? 1 : 3) })
        var previous = SIMD2(Double(start.x), Double(start.y)), index = 1
        #expect(path.points[0] == ScenePoint(x: previous.x, y: previous.y))
        for (control, endpoint) in zip(controls, ends) {
            let end = SIMD2(Double(endpoint.x), Double(endpoint.y))
            if let control {
                let control = SIMD2(Double(control.x), Double(control.y))
                let first = previous + (control - previous) * (2.0 / 3)
                let second = end + (control - end) * (2.0 / 3)
                #expect(abs(path.points[index].x - first.x) < 1e-12 && abs(path.points[index].y - first.y) < 1e-12)
                #expect(abs(path.points[index + 1].x - second.x) < 1e-12 && abs(path.points[index + 1].y - second.y) < 1e-12)
                index += 2
            }
            #expect(path.points[index] == ScenePoint(x: end.x, y: end.y))
            previous = end
            index += 1
        }
    }

    /// 构造源正权重四分圆，不用期望输出反推输入。
    private func quarter() throws -> StrokeConicCurve {
        try StrokeConicCurve(start: SIMD2(1, 0), control: SIMD2(1, 1), end: SIMD2(0, 1), weight: Float(bitPattern: 0x3F3504F3))
    }

    /// 保留独立Python/Swift公式交叉核对后的Float位模式。
    private func bits(_ x: UInt32, _ y: UInt32) -> SIMD2<Float> { SIMD2(Float(bitPattern: x), Float(bitPattern: y)) }
}
