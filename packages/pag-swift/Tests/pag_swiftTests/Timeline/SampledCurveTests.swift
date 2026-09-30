import Testing
@testable import pag_swift

/// 曲线细分、长度采样、退化、预算和取消，验证载入预计算不会变成无界工作。
struct SampledCurveTests {
    /// 共线控制点只需首末两点；空间比例按弧长而不是非均匀的 cubic t 参数。
    @Test func collinearSpatialCurveUsesLength() throws {
        var budget = DecodeBudget(limit: 1_000_000)
        let curve = try SampledCurve.make(start: .zero, control1: .zero, control2: .zero,
                                          end: ScenePoint(x: 100, y: 0), precision: 0.05, budget: &budget)
        #expect(curve.sampleCount == 2)
        #expect(curve.position(at: 0.25) == ScenePoint(x: 25, y: 0))
        #expect(curve.position(at: -1) == .zero)
        #expect(curve.position(at: 2) == ScenePoint(x: 100, y: 0))
    }

    /// 首末重合沿上游 PointOnLine 判定退化，不能出现除零或非有限位置。
    @Test func coincidentEndpointsRemainFinite() throws {
        var budget = DecodeBudget(limit: 1_000_000)
        let curve = try SampledCurve.make(start: .zero, control1: ScenePoint(x: 20, y: 0),
                                          control2: ScenePoint(x: 0, y: 20), end: .zero,
                                          precision: 0.05, budget: &budget)
        #expect(curve.sampleCount == 2 && curve.position(at: 0.5) == .zero)
    }

    /// 对称拱形在一半弧长处位于顶点，结果来自曲线分割而不是简单端点插值。
    @Test func curvedPathUsesAccumulatedDistance() throws {
        var budget = DecodeBudget(limit: 1_000_000)
        let curve = try SampledCurve.make(start: .zero, control1: ScenePoint(x: 0, y: 100),
                                          control2: ScenePoint(x: 100, y: 100), end: ScenePoint(x: 100, y: 0),
                                          precision: 0.05, budget: &budget)
        let middle = curve.position(at: 0.5)
        #expect(curve.sampleCount > 2)
        #expect(abs(middle.x - 50) < 0.05 && abs(middle.y - 75) < 0.05)
    }

    /// 细分点逐个计费，初始栈预算能容纳也不代表可以无限扩展曲线。
    @Test func segmentAllocationIsBudgeted() throws {
        var budget = DecodeBudget(limit: 2112)
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) {
            try SampledCurve.make(start: .zero, control1: ScenePoint(x: 0, y: 100),
                                  control2: ScenePoint(x: 100, y: 100), end: ScenePoint(x: 100, y: 0),
                                  precision: 0.05, budget: &budget)
        }
    }

    /// 不可表示的曲线及平方距离溢出都失败，不能发布含 NaN 的采样表。
    @Test func invalidCoordinatesFail() throws {
        var budget = DecodeBudget(limit: 1_000_000)
        for end in [ScenePoint(x: .infinity, y: 0), ScenePoint(x: 1e30, y: 0)] {
            #expect(throws: SceneValidator.invalid("unrepresentableCurve")) {
                try SampledCurve.make(start: .zero, control1: .zero, control2: end, end: end,
                                      precision: 0.05, budget: &budget)
            }
        }
    }

    /// 预取消的构建任务不能发布曲线，循环内部检查标准 CancellationError。
    @Test func cancelledConstructionStops() async throws {
        await #expect(throws: CancellationError.self) {
            try await withThrowingTaskGroup(of: SampledCurve.self) { group in
                group.cancelAll()
                group.addTask {
                    var budget = DecodeBudget(limit: 1_000_000)
                    return try SampledCurve.make(start: .zero, control1: .zero, control2: .one, end: .one,
                                                 precision: 0.005, budget: &budget)
                }
                for try await _ in group {}
            }
        }
    }
}
