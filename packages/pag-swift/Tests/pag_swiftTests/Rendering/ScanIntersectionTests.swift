import Testing
@testable import pag_swift

/// 交点事件必须有同高度符号证书；独立期望防止只把错误事件附近的误差放宽。
struct ScanIntersectionTests {
    /// list/16第49帧旧事件偏离六个ULP；两个操作数顺序都必须落在独立有理数根包围内。
    @Test(arguments: [false, true])
    func realIntersectionIsBracketed(_ swapped: Bool) throws {
        let left = ScanBoundary(ScenePoint(x: 3.0163239034591243, y: 8.362277614418417),
                                ScenePoint(x: 3.506469796411693, y: 9.299997482448816))
        let right = ScanBoundary(ScenePoint(x: 2.7423828169703484, y: 7.870894894003868),
                                 ScenePoint(x: 3.5141754237702116, y: 9.312493627658114))
        var budget = try GeometryBudget()
        let result = try #require(ScanIntersection.height(swapped ? right : left, swapped ? left : right, budget: &budget))
        // 这两个十六进制值由源Double的精确Fraction交点获得，不从生产求根器生成。
        #expect(result == 0x1.2709201efcc35p+3 || result == 0x1.2709201efcc36p+3)
        #expect(try ScanExactSign.difference(left, right, at: result.nextDown, budget: &budget) == 1)
        #expect(try ScanExactSign.difference(left, right, at: result.nextUp, budget: &budget) == -1)
    }

    /// 精确二分根、负高度根和有符号零均保留同一内部交点，不把零错作无交点。
    @Test(arguments: [(-2.0, 0.0, -1.0), (-1.0, 1.0, 0.0), (-0.0, 2.0, 1.0)])
    func exactRepresentableRoot(_ values: (Double, Double, Double)) throws {
        let left = ScanBoundary(ScenePoint(x: 0, y: values.0), ScenePoint(x: 2, y: values.1))
        let right = ScanBoundary(ScenePoint(x: 2, y: values.0), ScenePoint(x: 0, y: values.1))
        var budget = try GeometryBudget()
        #expect(try ScanIntersection.height(left, right, budget: &budget) == values.2)
    }

    /// 非对称跨零域的位序中点原本是subnormal；应先检测精确零，保留整数边的真实交点。
    @Test func asymmetricDomainFindsZeroWithoutSubnormalProbe() throws {
        let left = ScanBoundary(ScenePoint(x: -2, y: -2), ScenePoint(x: 1, y: 1))
        let right = ScanBoundary(ScenePoint(x: 0, y: -2), ScenePoint(x: 0, y: 1))
        var budget = try GeometryBudget()
        #expect(try ScanIntersection.height(left, right, budget: &budget) == 0)
    }

    /// 归一化x分量下溢使旧叉积候选消失；端点符号与位序收窄仍能找到跨600指数的真实根。
    @Test func lostCandidateStillFindsWideExponentRoot() throws {
        let width = Double(sign: .plus, exponent: -650, significand: 1)
        let height = Double(sign: .plus, exponent: 600, significand: 1)
        let left = ScanBoundary(.zero, ScenePoint(x: width, y: height))
        let right = ScanBoundary(ScenePoint(x: width, y: 0), ScenePoint(x: 0, y: height))
        var budget = try GeometryBudget(maximumWork: 20_000)
        #expect(try ScanIntersection.height(left, right, budget: &budget) == height / 2)
        #expect(budget.work < 20_000)
    }

    /// 相邻高度间没有内部Double时沿用原端点事件，不伪造中点，也不删除整个扫描带。
    @Test func adjacentDomainUsesExistingEndpoint() throws {
        let left = ScanBoundary(ScenePoint(x: 0, y: 1), ScenePoint(x: 2, y: 1.0.nextUp))
        let right = ScanBoundary(ScenePoint(x: 2, y: 1), ScenePoint(x: 0, y: 1.0.nextUp))
        var budget = try GeometryBudget()
        #expect(try ScanIntersection.height(left, right, budget: &budget) == nil)
    }

    /// 平行、共线、共享首末端点和仅域端点相接均不新增内部事件。
    @Test func nonCrossingAndEndpointPairsHaveNoNewEvent() throws {
        let diagonal = ScanBoundary(.zero, ScenePoint(x: 2, y: 2))
        let others = [
            ScanBoundary(ScenePoint(x: 1, y: 0), ScenePoint(x: 3, y: 2)),
            diagonal,
            ScanBoundary(.zero, ScenePoint(x: 3, y: 2)),
            ScanBoundary(ScenePoint(x: 3, y: 0), ScenePoint(x: 2, y: 2)),
            ScanBoundary(ScenePoint(x: 2, y: 2), ScenePoint(x: 0, y: 3)),
            ScanBoundary(ScenePoint(x: 1, y: 1), ScenePoint(x: 4, y: 2))
        ]
        for other in others {
            var budget = try GeometryBudget()
            #expect(try ScanIntersection.height(diagonal, other, budget: &budget) == nil)
        }
    }

    /// 整数共线边经归一化会产生伪非零叉积，候选10.5即使h为零也不能证明唯一交点。
    @Test func roundedCrossProductDoesNotInventCollinearEvent() throws {
        let left = ScanBoundary(.zero, ScenePoint(x: 9, y: 21))
        let right = ScanBoundary(ScenePoint(x: 3, y: 7), ScenePoint(x: 72, y: 168))
        var budget = try GeometryBudget()
        #expect(try ScanIntersection.height(left, right, budget: &budget) == nil)
    }

    /// 候选求值前的取消与符号查询的工作/临时存储超限必须传播，不能返回部分事件。
    @Test func eventProofRespectsLimitsAndCancellation() async throws {
        let left = ScanBoundary(.zero, ScenePoint(x: 2, y: 2))
        let right = ScanBoundary(ScenePoint(x: 2, y: 0), ScenePoint(x: 0, y: 2))
        var work = try GeometryBudget(maximumWork: 16)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryWork")) {
            try ScanIntersection.height(left, right, budget: &work)
        }
        var bytes = try GeometryBudget(maximumBytes: 16)
        #expect(throws: PAGError.resourceLimitExceeded("maximumRenderGeometryBytes")) {
            try ScanIntersection.height(left, right, budget: &bytes)
        }
        let task = Task {
            var budget = try GeometryBudget()
            withUnsafeCurrentTask { $0?.cancel() }
            return try ScanIntersection.height(left, right, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
