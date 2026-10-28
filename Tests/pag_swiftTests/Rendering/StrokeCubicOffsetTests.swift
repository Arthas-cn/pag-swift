import Testing
@testable import pag_swift

/// 单侧偏移的独立公式期望与有界递归测试；不把helper通过宣称为完整Stroke支持。
struct StrokeCubicOffsetTests {
    /// 手算凸拱半径1时两侧各两个quadratic，控制点精确为整数。
    @Test func archProducesIndependentExactQuadratics() throws {
        let points: [SIMD2<Float>] = [.zero, SIMD2(0, 4), SIMD2(4, 4), SIMD2(4, 0)]
        let outer = try outline(points, radius: 1, side: 1), inner = try outline(points, radius: 1, side: -1)
        try expectSegments(outer, start: SIMD2(1, 0), controls: [SIMD2(1, 2), SIMD2(3, 2)], ends: [SIMD2(2, 2), SIMD2(3, 0)])
        try expectSegments(inner, start: SIMD2(-1, 0), controls: [SIMD2(-1, 4), SIMD2(5, 4)], ends: [SIMD2(2, 4), SIMD2(5, 0)])
    }

    /// 源Float宽偏移保留一ULP不对称；不能先用Double算出漂亮的对称控制点。
    @Test func wideArchRetainsFloatControls() throws {
        let points: [SIMD2<Float>] = [.zero, SIMD2(0, 4), SIMD2(4, 4), SIMD2(4, 0)]
        let path = try outline(points, radius: 8, side: 1)
        try expectSegments(path, start: SIMD2(8, 0),
            controls: [SIMD2(Float(bitPattern: 0x40ffffff), Float(bitPattern: 0xbfa00004)),
                       SIMD2(Float(bitPattern: 0x40a60001), -5), SIMD2(-1.1875004768371582, -5), SIMD2(-4, -1.2500004768371582)],
            ends: [SIMD2(7.025000095367432, -2.5500001907348633), SIMD2(2, -5),
                   SIMD2(-3.0250000953674316, -2.5500001907348633), SIMD2(-4, 0)])
    }

    /// 左后代首次找到切线后右兄弟必须继承true；独立源码公式期望QQQLQ，局部状态会误成6Q。
    @Test func tangentsStateIsSharedAcrossSiblings() throws {
        let points: [SIMD2<Float>] = [.zero, SIMD2(-1, 2), SIMD2(0, 2), SIMD2(1, 0)]
        let path = try outline(points, radius: 1, side: 1)
        try expectSegments(path, start: SIMD2(0.8944271802902222, 0.4472135901451111),
            controls: [SIMD2(0.6168649196624756, 1.0023380517959595), SIMD2(0.5971361994743347, 1.1601685285568237),
                       SIMD2(0.30831241607666016, 0.5), nil, SIMD2(-0.19122156500816345, 0.14637522399425507)],
            ends: [SIMD2(0.5860278606414795, 1.2490347623825073), SIMD2(0.5294385552406311, 1.0054311752319336),
                   SIMD2(-0.25, 0.5), SIMD2(-0.47132670879364014, 0.4664953947067261), SIMD2(0.10557281970977783, -0.4472135901451111)])
    }

    /// 两个拐点区间独立重置状态；S形两侧段数不同也是源码Float结果。
    @Test func inflectionIntervalsResetStateForEachSide() throws {
        let points: [SIMD2<Float>] = [.zero, SIMD2(2, 2), SIMD2(2, -2), SIMD2(4, 0)]
        let outer = try outline(points, radius: 1, side: 1, intervals: [0, 0.5, 1])
        let inner = try outline(points, radius: 1, side: -1, intervals: [0, 0.5, 1])
        #expect(outer.verbs == [.move, .cubic, .cubic, .cubic, .close])
        #expect(inner.verbs == [.move, .cubic, .cubic, .close])
        #expect(outer.points[3] == ScenePoint(x: Double(Float(1.2928931713104248)), y: Double(Float(-0.7071067690849304))))
        #expect(inner.points[3] == ScenePoint(x: Double(Float(2.707106828689575)), y: Double(Float(0.7071067690849304))))
    }

    /// 尖点右半仍用全局t，Float停滞产生跨法线Line；不是重参数化后平滑的右半曲线。
    @Test func cuspIntervalPreservesGlobalRayAndStagnation() throws {
        let points: [SIMD2<Float>] = [.zero, SIMD2(4, 4), SIMD2(0, 4), SIMD2(4, 0)]
        let outer = try outline(points, radius: 2, side: 1, intervals: [0.5, 1])
        let inner = try outline(points, radius: 2, side: -1, intervals: [0.5, 1])
        #expect(outer.verbs == [.move] + Array(repeating: .line, count: 12) + Array(repeating: .cubic, count: 11) + [.close])
        #expect(inner.verbs == [.move] + Array(repeating: .line, count: 10) + [.cubic, .line] + Array(repeating: .cubic, count: 11) + [.close])
        #expect(outer.points[0] == ScenePoint(x: 4, y: 3))
        #expect(outer.points[1] == ScenePoint(x: 0, y: 3))
    }

    /// 15/24边界上可直接接受的叶节点成功，仍需细分的节点失败；低预算深度同样不能静默放宽。
    @Test func recursionLimitsApplyOnlyWhenSplitting() throws {
        let flat: [SIMD2<Float>] = [.zero, SIMD2(1, 0), SIMD2(2, 0), SIMD2(3, 0)]
        let arch: [SIMD2<Float>] = [.zero, SIMD2(0, 4), SIMD2(4, 4), SIMD2(4, 0)]
        for found in [false, true] {
            let depth = found ? 24 : 15
            var outputBudget = try GeometryBudget()
            let output = try StrokePathOutput(budget: &outputBudget, limits: .standard)
            let boundary = StrokeLineBoundary()
            let first = try StrokeCubicSampling.ray(flat, at: 0, radius: 1, side: 1, budget: &output.budget)
            let last = try StrokeCubicSampling.ray(flat, at: 1, radius: 1, side: 1, budget: &output.budget)
            try boundary.move(to: first.offset, output: output)
            var state = found
            try StrokeCubicOffset.append(flat, radius: 1, side: 1, quad: StrokeOffsetQuad(start: 0, end: 1, first: first, last: last),
                foundTangents: &state, depth: depth, to: boundary, output: output)
            #expect(boundary.last == last.offset)
            let a = try StrokeCubicSampling.ray(arch, at: 0, radius: 1, side: 1, budget: &output.budget)
            let b = try StrokeCubicSampling.ray(arch, at: 1, radius: 1, side: 1, budget: &output.budget)
            #expect(throws: PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")) {
                try StrokeCubicOffset.append(arch, radius: 1, side: 1, quad: StrokeOffsetQuad(start: 0, end: 1, first: a, last: b),
                    foundTangents: &state, depth: depth, to: boundary, output: output)
            }
        }
        #expect(throws: PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")) {
            try outline(arch, radius: 1, side: 1, budget: GeometryBudget(maximumDepth: 0))
        }
    }

    /// 注入有限端ray只验证递归控制器：左停滞补父终点，右停滞须保留已完成左半。
    @Test func leftAndRightStagnationPreserveSourceOrder() throws {
        let points: [SIMD2<Float>] = [.zero, SIMD2(0, 4), SIMD2(4, 4), SIMD2(4, 0)]
        for right in [false, true] {
            var outputBudget = try GeometryBudget()
            let output = try StrokePathOutput(budget: &outputBudget, limits: .standard)
            let boundary = StrokeLineBoundary()
            let start = SIMD2<Float>(0, right ? 2 : 0), end = SIMD2<Float>(4, right ? 3 : 0)
            let quad = StrokeOffsetQuad(start: 0.5, end: right ? Float(0.5).nextUp.nextUp.nextUp : Float(0.5).nextUp,
                first: StrokeOffsetRay(curve: start, offset: start, tangent: start + SIMD2(1, 0)),
                last: StrokeOffsetRay(curve: end, offset: end, tangent: end - SIMD2(1, 0)))
            try boundary.move(to: start, output: output)
            var found = false
            try StrokeCubicOffset.append(points, radius: 1, side: 1, quad: quad, foundTangents: &found, depth: 0, to: boundary, output: output)
            try boundary.emit(reversed: false, restoration: .identity, tolerance: 0.001, output: output)
            let path = try output.finish(restoring: .identity)
            if right {
                // 独立Float探针：左末切线有极小负y，实际先形成Q；右中点停滞才追加L。
                let leftEnd = SIMD2<Float>(Float(bitPattern: 0x40000001), 2)
                try expectSegments(path, start: start, controls: [leftEnd, nil], ends: [leftEnd, end])
                #expect(found)
            } else { #expect(path.verbs == [.move, .line, .close]) }
            #expect(path.points.last == StrokeLineMath.scene(end))
        }
    }

    /// 初次平行判据在中点距离恰为0.25时必须继续细分；已有切线状态则走无中点限制的Line分支。
    @Test func initialLinePredicateUsesStrictDistance() throws {
        let points: [SIMD2<Float>] = [.zero, SIMD2(1, 0), SIMD2(2, 0), SIMD2(3, 0)]
        let first = StrokeOffsetRay(curve: .zero, offset: SIMD2(0, -1.25), tangent: SIMD2(1, -1.25))
        let last = StrokeOffsetRay(curve: SIMD2(3, 0), offset: SIMD2(3, -1.25), tangent: SIMD2(4, -1.25))
        let quad = StrokeOffsetQuad(start: 0, end: 1, first: first, last: last)
        var outputBudget = try GeometryBudget(maximumDepth: 0)
        let output = try StrokePathOutput(budget: &outputBudget, limits: .standard)
        let boundary = StrokeLineBoundary()
        try boundary.move(to: first.offset, output: output)
        var found = false
        #expect(throws: PAGError.resourceLimitExceeded("maximumGeometryCurveDepth")) {
            try StrokeCubicOffset.append(points, radius: 1, side: 1, quad: quad, foundTangents: &found, depth: 0, to: boundary, output: output)
        }
        found = true
        try StrokeCubicOffset.append(points, radius: 1, side: 1, quad: quad, foundTangents: &found, depth: 0, to: boundary, output: output)
        #expect(boundary.last == last.offset)
    }

    /// 单侧局部前缀不授权发布；任何预算、输出或取消失败均抛出而不返回部分路径。
    @Test func limitsAndCancellationAbortCandidate() async throws {
        let points: [SIMD2<Float>] = [.zero, SIMD2(0, 4), SIMD2(4, 4), SIMD2(4, 0)]
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try outline(points, radius: 1, side: 1, budget: GeometryBudget(maximumWork: 200))
        }
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try outline(points, radius: 1, side: 1, budget: GeometryBudget(maximumBytes: 500))
        }
        #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeOutputElements")) {
            try outline(points, radius: 1, side: 1, limits: StrokeBackendLimits(maximumOutputElements: 1))
        }
        let task = Task {
            let budget = try GeometryBudget()
            withUnsafeCurrentTask { $0?.cancel() }
            return try outline(points, radius: 1, side: 1, budget: budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 第一段Q已完整留在局部边界后，后半区间的工作/字节不足仍禁止所有者返回SourcePath。
    @Test func budgetsFailAfterACompletedPrefix() throws {
        let cases: [(GeometryBudget, PAGError)] = [
            (try GeometryBudget(maximumWork: 250), .resourceLimitExceeded("maximumRenderGeometryWork")),
            (try GeometryBudget(maximumBytes: 500), .resourceLimitExceeded("maximumRenderGeometryBytes"))
        ]
        for (budget, expected) in cases {
            // 前缀在预期失败捕获之外完成；若预算太小导致前缀本身失败，整个测试必须失败。
            let (boundary, output) = try prefix(budget: budget)
            #expect(throws: expected) { try finishAfterNext(boundary, output: output) }
        }
    }

    /// 先成功追加Q，再以有限但会溢出的控制点继续；不能把旧前缀包装成成功候选。
    @Test func finiteNumericFailureDoesNotPublishPrefix() throws {
        let (boundary, output) = try prefix(budget: GeometryBudget())
        let huge = Float.greatestFiniteMagnitude
        let next: [SIMD2<Float>] = [.zero, SIMD2(huge, huge), SIMD2(-huge, huge), .zero]
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try finishAfterNext(boundary, output: output, points: next)
        }
    }

    /// 成功前缀后在同一任务确定性取消；下一节点立即抛取消，不等到输出整个轮廓后才检查。
    @Test func cancellationAfterPrefixPreventsPublication() async throws {
        let task = Task {
            let (boundary, output) = try prefix(budget: GeometryBudget())
            withUnsafeCurrentTask { $0?.cancel() }
            return try finishAfterNext(boundary, output: output)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 在捕获预期失败之外建立手算拱的首半Q，返回仅供测试所有者本地使用的未发布边界。
    private func prefix(budget: GeometryBudget) throws -> (StrokeLineBoundary, StrokePathOutput) {
        let points: [SIMD2<Float>] = [.zero, SIMD2(0, 4), SIMD2(4, 4), SIMD2(4, 0)]
        var outputBudget = budget
        let output = try StrokePathOutput(budget: &outputBudget, limits: .standard)
        let boundary = StrokeLineBoundary()
        try boundary.move(to: SIMD2(1, 0), output: output)
        try StrokeCubicOffset.append(points, radius: 1, side: 1, start: 0, end: 0.5, to: boundary, output: output)
        #expect(boundary.last == SIMD2(2, 2))
        return (boundary, output)
    }

    /// 模拟完整候选所有者：下一段、统一转换和finish全部成功后才能返回，错误一律传播。
    private func finishAfterNext(_ boundary: StrokeLineBoundary, output: StrokePathOutput,
                                 points: [SIMD2<Float>] = [.zero, SIMD2(0, 4), SIMD2(4, 4), SIMD2(4, 0)]) throws -> SourcePath {
        try StrokeCubicOffset.append(points, radius: 1, side: 1, start: 0.5, end: 1, to: boundary, output: output)
        try boundary.emit(reversed: false, restoration: .identity, tolerance: 0.001, output: output)
        return try output.finish(restoring: .identity)
    }

    /// 独立比较quadratic控制点及末点；仅以精确2/3关系转换期望，不调用生产几何生成期望。
    private func expectSegments(_ path: SourcePath, start: SIMD2<Float>, controls: [SIMD2<Float>?], ends: [SIMD2<Float>]) throws {
        #expect(path.verbs == [.move] + controls.map { $0 == nil ? .line : .cubic } + [.close])
        try #require(path.points.count == 1 + controls.reduce(0) { $0 + ($1 == nil ? 1 : 3) })
        var previous = StrokeLineMath.scene(start), index = 1
        #expect(path.points[0] == previous)
        for (control, end) in zip(controls, ends) {
            let end = StrokeLineMath.scene(end)
            if let control {
                let control = StrokeLineMath.scene(control)
                let a = ScenePoint(x: previous.x + (control.x - previous.x) * (2.0 / 3), y: previous.y + (control.y - previous.y) * (2.0 / 3))
                let b = ScenePoint(x: end.x + (control.x - end.x) * (2.0 / 3), y: end.y + (control.y - end.y) * (2.0 / 3))
                #expect(abs(path.points[index].x - a.x) < 1e-12 && abs(path.points[index].y - a.y) < 1e-12)
                #expect(abs(path.points[index + 1].x - b.x) < 1e-12 && abs(path.points[index + 1].y - b.y) < 1e-12)
                index += 2
            }
            #expect(path.points[index] == end)
            previous = end
            index += 1
        }
    }

    /// 单侧测试拥有整次局部输出，任一步失败都不会返回SourcePath；只关闭边界以便读取。
    private func outline(_ points: [SIMD2<Float>], radius: Float, side: Float, intervals: [Float] = [0, 1],
                         budget: GeometryBudget? = nil, limits: StrokeBackendLimits = .standard) throws -> SourcePath {
        var outputBudget = try budget ?? GeometryBudget()
        let output = try StrokePathOutput(budget: &outputBudget, limits: limits)
        let boundary = StrokeLineBoundary()
        let first = try StrokeCubicSampling.ray(points, at: intervals[0], radius: radius, side: side, budget: &output.budget)
        try boundary.move(to: first.offset, output: output)
        for index in 1..<intervals.count {
            try StrokeCubicOffset.append(points, radius: radius, side: side, start: intervals[index - 1], end: intervals[index], to: boundary, output: output)
        }
        try boundary.emit(reversed: false, restoration: .identity, tolerance: 0.001, output: output)
        return try output.finish(restoring: .identity)
    }
}
