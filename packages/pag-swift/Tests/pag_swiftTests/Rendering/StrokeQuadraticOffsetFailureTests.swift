import Testing
@testable import pag_swift

/// 单侧偏移的完整候选失败语义；先完成前缀，再注入下一段错误，不能以局部成功发布路径。
struct StrokeQuadraticOffsetFailureTests {
    /// 第一条Q完成后下一条工作或字节不足，拥有者抛错且保留已消费预算。
    @Test func budgetsFailAfterCompletedPrefix() throws {
        for value: (GeometryBudget, PAGError) in [
            (try GeometryBudget(maximumWork: 420), .resourceLimitExceeded("maximumRenderGeometryWork")),
            (try GeometryBudget(maximumBytes: 600), .resourceLimitExceeded("maximumRenderGeometryBytes"))
        ] {
            let (boundary, output) = try prefix(budget: value.0)
            let previousWork = output.budget.work
            #expect(throws: value.1) { try finishAfterNext(boundary, output: output) }
            #expect(output.budget.work > previousWork)
        }
    }

    /// 元素预算按真实局部边界输出计费，不能在前缀后把后段失败当作结束。
    @Test func elementLimitRejectsSecondQuadratic() throws {
        let (boundary, output) = try prefix(budget: GeometryBudget(), limits: StrokeBackendLimits(maximumOutputElements: 1))
        #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeOutputElements")) {
            try finishAfterNext(boundary, output: output)
        }
    }

    /// 有限控制点与正权重仍可能在求值系数中溢出；不能返回已经完成的前一条Q。
    @Test func arithmeticFailureDiscardsCandidate() throws {
        let (boundary, output) = try prefix(budget: GeometryBudget())
        let bad = try StrokeConicCurve(start: SIMD2(0, 1), control: SIMD2(-1, 1), end: SIMD2(-1, 0), weight: .greatestFiniteMagnitude)
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try finishAfterNext(boundary, output: output, curve: bad)
        }
    }

    /// 完成前缀后确定性取消；后段入口传播CancellationError，拥有者没有发布出口。
    @Test func cancellationAfterPrefixPreventsPublication() async throws {
        let task = Task {
            let (boundary, output) = try prefix(budget: GeometryBudget())
            withUnsafeCurrentTask { $0?.cancel() }
            return try finishAfterNext(boundary, output: output)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 在错误捕获之外实际完成第一条quarter Q；准备阶段若已超预算必须让整个测试失败。
    private func prefix(budget: GeometryBudget, limits: StrokeBackendLimits = .standard) throws -> (StrokeLineBoundary, StrokePathOutput) {
        var budget = budget
        let output = try StrokePathOutput(budget: &budget, limits: limits)
        let boundary = StrokeLineBoundary()
        try boundary.move(to: SIMD2(2, 0), output: output)
        let curve = try StrokeConicCurve(start: SIMD2(1, 0), control: SIMD2(1, 1), end: SIMD2(0, 1), weight: Float(bitPattern: 0x3F3504F3))
        try StrokeQuadraticOffset.append(curve, radius: 1, side: 1, to: boundary, output: output)
        #expect(boundary.last == SIMD2(0, 2))
        return (boundary, output)
    }

    /// 模拟完整拥有者，只有后段、边界出口和finish全成功才返回SourcePath。
    private func finishAfterNext(_ boundary: StrokeLineBoundary, output: StrokePathOutput,
                                 curve: StrokeConicCurve? = nil) throws -> SourcePath {
        let next = try curve ?? StrokeConicCurve(start: SIMD2(0, 1), control: SIMD2(-1, 1), end: SIMD2(-1, 0),
                                                weight: Float(bitPattern: 0x3F3504F3))
        try StrokeQuadraticOffset.append(next, radius: 1, side: 1, to: boundary, output: output)
        try boundary.emit(reversed: false, restoration: .identity, tolerance: 0.001, output: output)
        return try output.finish()
    }
}
