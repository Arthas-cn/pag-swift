import Testing
@testable import pag_swift

/// 固定PathKit三点分类的独立Float夹具，覆盖Quad/Conic分支差异与有界失败，不生成PAG字节。
struct StrokeQuadraticAnalysisTests {
    /// 全相等才为point，任一控制边重复为line；不能把非零的小控制边按距离阈值删掉。
    @Test func repeatedControlPointsChoosePointOrLine() throws {
        let cases: [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, StrokeQuadraticReduction)] = [
            (SIMD2(3, 4), SIMD2(3, 4), SIMD2(3, 4), .point),
            (.zero, .zero, SIMD2(2, 3), .line),
            (.zero, SIMD2(2, 3), SIMD2(2, 3), .line),
            (.zero, SIMD2(1, 0), SIMD2(2, 0), .line)
        ]
        for (start, control, end, expected) in cases {
            var budget = try GeometryBudget()
            let quad = try StrokeQuadCurve(start: start, control: control, end: end)
            let conic = try StrokeConicCurve(start: start, control: control, end: end, weight: 0.5)
            #expect(matches(try StrokeQuadraticAnalysis.reduction(of: quad, budget: &budget), expected))
            #expect(matches(try StrokeQuadraticAnalysis.reduction(of: conic, budget: &budget), expected))
        }
    }

    /// 同一回折控制多边形共用t=0.5，但回折点必须分别来自普通和有理Horner公式。
    @Test func reversalPositionsUseEachOriginalCurve() throws {
        var budget = try GeometryBudget()
        let quad = try StrokeQuadCurve(start: .zero, control: SIMD2(4, 0), end: .zero)
        let conic = try StrokeConicCurve(start: .zero, control: SIMD2(4, 0), end: .zero, weight: 0.5)
        #expect(matches(try StrokeQuadraticAnalysis.reduction(of: quad, budget: &budget), .reversal(point: SIMD2(2, 0))))
        // 源Conic在t=0.5的分子为1、分母为0.75；独立Float除法得到0x3FAAAAAB。
        let expected = SIMD2<Float>(Float(bitPattern: 0x3FAAAAAB), 0)
        #expect(matches(try StrokeQuadraticAnalysis.reduction(of: conic, budget: &budget), .reversal(point: expected)))
    }

    /// 最大曲率t=1时Quad直接降Line，Conic仍取原Horner回折点，不能替换成存储终点。
    @Test func upperCurvatureEndpointKeepsConicReversal() throws {
        var budget = try GeometryBudget()
        let quad = try StrokeQuadCurve(start: .zero, control: SIMD2(4, 0), end: SIMD2(6, 0))
        #expect(matches(try StrokeQuadraticAnalysis.reduction(of: quad, budget: &budget), .line))
        let cases: [(Float, Float)] = [(0.5, 6), (16_777_216, 8)]
        for (weight, endpoint) in cases {
            let conic = try StrokeConicCurve(start: .zero, control: SIMD2(4, 0), end: SIMD2(6, 0), weight: weight)
            // 大权重时Float分子系数相消只留下8；没有调用生产求值器生成这个期望。
            #expect(matches(try StrokeQuadraticAnalysis.reduction(of: conic, budget: &budget), .reversal(point: SIMD2(endpoint, 0))))
        }
    }

    /// 曲率t=0先于零分母处理，两种类型都直接降Line，不进入回折点求值。
    @Test func lowerCurvatureEndpointAndZeroDenominatorBecomeLine() throws {
        for end: Float in [2, 3] {
            var budget = try GeometryBudget()
            let quad = try StrokeQuadCurve(start: .zero, control: SIMD2(1, 0), end: SIMD2(end, 0))
            let conic = try StrokeConicCurve(start: .zero, control: SIMD2(1, 0), end: SIMD2(end, 0), weight: 0.5)
            #expect(matches(try StrokeQuadraticAnalysis.reduction(of: quad, budget: &budget), .line))
            #expect(matches(try StrokeQuadraticAnalysis.reduction(of: conic, budget: &budget), .line))
        }
    }

    /// 普通拱、quarter和大平移拱均保留真正曲线；ray后续的Float反向退化不能倒灌分类。
    @Test func nonlinearControlPolygonsRemainCurves() throws {
        let cases: [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)] = [
            (.zero, SIMD2(1, 1), SIMD2(2, 0)),
            (SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)),
            (SIMD2(8_388_608, 0), SIMD2(8_389_632, 2_048), SIMD2(8_390_656, 0))
        ]
        for (start, control, end) in cases {
            var budget = try GeometryBudget()
            let quad = try StrokeQuadCurve(start: start, control: control, end: end)
            let conic = try StrokeConicCurve(start: start, control: control, end: end, weight: 0.5)
            #expect(matches(try StrokeQuadraticAnalysis.reduction(of: quad, budget: &budget), .curve))
            #expect(matches(try StrokeQuadraticAnalysis.reduction(of: conic, budget: &budget), .curve))
        }
    }

    /// 相邻Float高度跨越源5e-6平方距离门槛，近共线一侧保留t=0.5回折点而另一侧为curve。
    @Test func adjacentHeightsStraddleCurvatureSlop() throws {
        var budget = try GeometryBudget()
        let below = Float(bitPattern: 0x3B128AFE), above = Float(bitPattern: 0x3B128AFF)
        #expect(below.nextUp == above)
        // 独立binary32公式给出h²分别为0x36A7C5AA/0x36A7C5AD；slop是0x36A7C5AC。
        let near = try StrokeQuadCurve(start: .zero, control: SIMD2(0.5, below), end: SIMD2(1, 0))
        let curved = try StrokeQuadCurve(start: .zero, control: SIMD2(0.5, above), end: SIMD2(1, 0))
        let reduction = SIMD2<Float>(0.5, Float(bitPattern: 0x3A928AFE))
        #expect(matches(try StrokeQuadraticAnalysis.reduction(of: near, budget: &budget), .reversal(point: reduction)))
        #expect(matches(try StrokeQuadraticAnalysis.reduction(of: curved, budget: &budget), .curve))
    }

    /// 最大L∞跨度相等时保留首个点对；换成后一个水平基线会把此例错误分类为curve。
    @Test func equalMaximumSpansKeepTheFirstPair() throws {
        var budget = try GeometryBudget()
        let height = Float(bitPattern: 0x3B128AFF)
        let quad = try StrokeQuadCurve(start: .zero, control: SIMD2(1, height), end: SIMD2(1, 0))
        // 首个斜基线距离²为0x36A7C576，水平基线为0x36A7C5AD；仅前者不超过slop。
        // 源t=0x3F7FFF58，独立Horner得到终点附近但非零的y，不能吸附到存储终点。
        let expected = SIMD2<Float>(1, Float(bitPattern: 0x333FFF82))
        #expect(matches(try StrokeQuadraticAnalysis.reduction(of: quad, budget: &budget), .reversal(point: expected)))
    }

    /// 极小三角形投影产生0/0时按源回退到lineStart距离，不能仅因投影NaN报精度失败。
    @Test func underflowedProjectionUsesFiniteFallbackDistance() throws {
        let tiny = Float(sign: .plus, exponent: -100, significand: 1)
        var budget = try GeometryBudget()
        #expect(tiny != 0 && tiny * tiny == 0)
        let quad = try StrokeQuadCurve(start: .zero, control: SIMD2(tiny, tiny), end: SIMD2(2 * tiny, 0))
        let conic = try StrokeConicCurve(start: .zero, control: SIMD2(tiny, tiny), end: SIMD2(2 * tiny, 0), weight: 0.5)
        #expect(matches(try StrokeQuadraticAnalysis.reduction(of: quad, budget: &budget), .line))
        #expect(matches(try StrokeQuadraticAnalysis.reduction(of: conic, budget: &budget), .line))
    }

    /// 有限输入的控制边、slop、曲率平方和或回折Horner溢出都明确失败，不伪装成降阶成功。
    @Test func nonrepresentableAnalysisFailsExplicitly() throws {
        var budget = try GeometryBudget()
        let limit = Float.greatestFiniteMagnitude
        let cases: [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)] = [
            (SIMD2(-limit, 0), SIMD2(limit, 0), SIMD2(limit, 0)),
            (.zero, SIMD2(1e20, 0), SIMD2(2e20, 0)),
            (.zero, SIMD2(1e19, 0), .zero)
        ]
        for (start, control, end) in cases {
            let quad = try StrokeQuadCurve(start: start, control: control, end: end)
            #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
                try StrokeQuadraticAnalysis.reduction(of: quad, budget: &budget)
            }
        }
        let conic = try StrokeConicCurve(start: .zero, control: SIMD2(4, 0), end: .zero,
                                        weight: Float(sign: .plus, exponent: 126, significand: 1))
        #expect(throws: PAGError.resourceLimitExceeded("geometryPrecision")) {
            try StrokeQuadraticAnalysis.reduction(of: conic, budget: &budget)
        }
    }

    /// 固定分类和随后回折求值共用工作预算；取消发生在point快路前也必须传播。
    @Test func workAndCancellationPrecedeClassification() async throws {
        let quad = try StrokeQuadCurve(start: .zero, control: SIMD2(4, 0), end: .zero)
        let conic = try StrokeConicCurve(start: .zero, control: SIMD2(4, 0), end: .zero, weight: 0.5)
        var initial = try GeometryBudget(maximumWork: 63)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try StrokeQuadraticAnalysis.reduction(of: quad, budget: &initial)
        }
        var followup = try GeometryBudget(maximumWork: 95)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try StrokeQuadraticAnalysis.reduction(of: conic, budget: &followup)
        }
        #expect(followup.work == 64)
        for isConic in [false, true] {
            let task = Task {
                var local = try GeometryBudget()
                let point = try StrokeQuadCurve(start: .zero, control: .zero, end: .zero)
                let rational = try StrokeConicCurve(start: .zero, control: .zero, end: .zero, weight: 0.5)
                // 由执行测试的子任务自行取消，不依赖调度先后或sleep。
                withUnsafeCurrentTask { $0?.cancel() }
                if isConic { return try StrokeQuadraticAnalysis.reduction(of: rational, budget: &local) }
                return try StrokeQuadraticAnalysis.reduction(of: point, budget: &local)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }

    /// 只比较分类及关联点，避免为测试修改生产枚举的协议；不复算任何几何期望。
    private func matches(_ actual: StrokeQuadraticReduction, _ expected: StrokeQuadraticReduction) -> Bool {
        switch (actual, expected) {
        case (.point, .point), (.line, .line), (.curve, .curve): true
        case (.reversal(let first), .reversal(let second)): first == second
        default: false
        }
    }
}
