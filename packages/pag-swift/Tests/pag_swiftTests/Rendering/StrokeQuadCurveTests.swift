import Testing
@testable import pag_swift

/// 用独立源码Float位模式验证Quad基础几何，不借生产切分器构造期望。
struct StrokeQuadCurveTests {
    /// Horner位置和普通切线保留原公式，端控制点重复时切线直接用首末差而非零向量。
    @Test func positionsAndEndpointTangentsFollowSource() throws {
        let curve = try arch()
        var budget = try GeometryBudget()
        #expect(try curve.position(at: 0.5, budget: &budget) == SIMD2(4, 4))
        #expect(try curve.tangent(at: 0.5, budget: &budget) == SIMD2(8, 0))
        #expect(try curve.tangent(at: 0, budget: &budget) == SIMD2(8, 16))
        for first in [true, false] {
            let end = SIMD2<Float>(3, 5)
            let value = try StrokeQuadCurve(start: .zero, control: first ? .zero : end, end: end)
            #expect(try value.tangent(at: first ? 0 : 1, budget: &budget) == end)
        }
    }

    /// 大坐标Horner末点可能不同于原P2；完整截取仍保留原始控制点，不能混用快路。
    @Test func endpointEvaluationAndWholeSegmentStayDistinct() throws {
        let curve = try StrokeQuadCurve(start: SIMD2(16_777_216, 0), control: .zero, end: SIMD2(1, 0))
        var budget = try GeometryBudget()
        #expect(try curve.position(at: 1, budget: &budget) == .zero)
        let full = try curve.segment(from: 0, to: 1, budget: &budget)
        #expect(full.start == curve.start && full.control == curve.control && full.end == curve.end)
        let pair = try curve.split(at: 0.5, budget: &budget)
        #expect(pair.first.control == SIMD2(8_388_608, 0) && pair.first.end == SIMD2(4_194_304, 0))
        #expect(pair.second.start == pair.first.end && pair.second.control == SIMD2(0.5, 0))
    }

    /// 非二进制参数逐步舍入，左右共享同一中点，不能把两侧控制点强制对称。
    @Test func thirdSplitPreservesExactFloatSequence() throws {
        var budget = try GeometryBudget()
        let pair = try arch().split(at: Float(1) / 3, budget: &budget)
        #expect(pair.first.start == .zero && pair.second.end == SIMD2(8, 0))
        #expect(pair.first.control == bits(0x3FAAAAAB, 0x402AAAAB))
        #expect(pair.first.end == bits(0x402AAAAB, 0x40638E39))
        #expect(pair.second.start == pair.first.end)
        #expect(pair.second.control == bits(0x40AAAAAB, 0x40AAAAAA))
    }

    /// 内部截取先切尾部再以Float归一参数切头，独立期望保留不对称的一ULP末点。
    @Test func interiorSegmentKeepsRenormalizationRounding() throws {
        var budget = try GeometryBudget()
        let third = try arch().segment(from: Float(1) / 3, to: Float(2) / 3, budget: &budget)
        #expect(third.start == bits(0x402AAAAB, 0x40638E39))
        #expect(third.control == bits(0x40800000, 0x408E38E4))
        #expect(third.end == bits(0x40AAAAAB, 0x40638E38))
        let decimal = try arch().segment(from: 0.2, to: 0.8, budget: &budget)
        #expect(decimal.start == bits(0x3FCCCCCD, 0x4023D70A))
        #expect(decimal.control == bits(0x40800000, 0x40AE147B))
        #expect(decimal.end == bits(0x40CCCCCC, 0x4023D70A))
    }

    /// 合法内部范围的第二次参数可舍为1，仍须执行插值，不能拒绝或直接返回右半原末点。
    @Test func normalizedEndpointStillExecutesChop() throws {
        let curve = try StrokeQuadCurve(start: .zero, control: SIMD2(1, 0), end: SIMD2(-1, 0))
        var budget = try GeometryBudget()
        let result = try curve.segment(from: Float(bitPattern: 0x33C00000), to: Float(1).nextDown, budget: &budget)
        #expect(result.start == bits(0x343FFFFE, 0))
        #expect(result.control == bits(0x3F7FFFFD, 0))
        #expect(result.end == bits(0xBF7FFFFF, 0))
        #expect(result.end != curve.end)
    }

    /// 输入点与参数非法均明确失败；方向溢出允许保留给ray，位置溢出则必须拒绝。
    @Test func invalidValuesRemainDistinctFromRawDirections() throws {
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try StrokeQuadCurve(start: .zero, control: SIMD2(.nan, 0), end: .zero)
        }
        var budget = try GeometryBudget()
        let curve = try arch()
        for parameter: Float in [-1, 2, .nan, .infinity] {
            #expect(throws: PAGError.invalidArgument("strokeCurveParameter")) {
                try curve.position(at: parameter, budget: &budget)
            }
        }
        for parameter: Float in [0, 1] {
            #expect(throws: PAGError.invalidArgument("strokeCurveParameter")) { try curve.split(at: parameter, budget: &budget) }
        }
        for range: (Float, Float) in [(0.5, 0.5), (0.7, 0.2), (-1, 1), (0, .nan)] {
            #expect(throws: PAGError.invalidArgument("strokeCurveRange")) {
                try curve.segment(from: range.0, to: range.1, budget: &budget)
            }
        }
        let huge = Float.greatestFiniteMagnitude
        let overflow = try StrokeQuadCurve(start: SIMD2(-huge, 0), control: SIMD2(huge, 0), end: .zero)
        #expect(try overflow.tangent(at: 0.5, budget: &budget).x.isNaN)
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) { try overflow.position(at: 0.5, budget: &budget) }
    }

    /// 工作或pair存储不足及预取消时不返回曲线，失败后保留已计工作。
    @Test func budgetsAndCancellationRejectResults() async throws {
        let curve = try arch()
        var work = try GeometryBudget(maximumWork: 31)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) { try curve.position(at: 0.5, budget: &work) }
        var bytes = try GeometryBudget(maximumBytes: 255)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) { try curve.split(at: 0.5, budget: &bytes) }
        #expect(bytes.work == 64)
        let task = Task {
            var budget = try GeometryBudget()
            withUnsafeCurrentTask { $0?.cancel() }
            return try curve.segment(from: 0, to: 1, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 整数控制点的解析拱形，独立Float期望不由生产方法求出。
    private func arch() throws -> StrokeQuadCurve { try StrokeQuadCurve(start: .zero, control: SIMD2(4, 8), end: SIMD2(8, 0)) }

    /// 将独立逐步Float探针的位模式直接载入，不用Double容差掩盖舍入差异。
    private func bits(_ x: UInt32, _ y: UInt32) -> SIMD2<Float> { SIMD2(Float(bitPattern: x), Float(bitPattern: y)) }
}
