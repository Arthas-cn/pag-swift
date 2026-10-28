import Testing
@testable import pag_swift

/// 共享测量表的独立Float记录期望，覆盖原始参数、严格阈值与距离舍入，不复用生产helper生成答案。
struct StrokeDashMetricTests {
    /// 共线Quad也按参数非匀速细分；恰好0.5偏差不细分，下一Float必须产生两条记录。
    @Test func collinearQuadUsesStrictThreshold() throws {
        for value: (Float, [Float], [UInt32]) in [
            (2, [1], [0x40000000]),
            (Float(2).nextUp, [0.5, 1], [0x3F000001, 0x40000001]),
            (4, [0.5, 1], [0x3F800000, 0x40800000])
        ] {
            var budget = try GeometryBudget()
            var metric = StrokeDashMetric()
            let curve = try StrokeQuadCurve(start: .zero, control: .zero, end: SIMD2(value.0, 0))
            try metric.append(curve, curveIndex: 7, budget: &budget)
            #expect(metric.records.map(\.parameter) == value.1)
            #expect(metric.records.map { $0.distance.bitPattern } == value.2)
            #expect(metric.records.allSatisfy { $0.curve == 7 })
        }
    }

    /// 同起终点的Quad在阈值内无叶弦长度，跨过阈值才测到往返，不能用视觉弯曲替代源谓词。
    @Test func returningQuadPreservesThresholdDiscontinuity() throws {
        var budget = try GeometryBudget()
        var metric = StrokeDashMetric()
        try metric.append(StrokeQuadCurve(start: .zero, control: SIMD2(0, 1), end: .zero), curveIndex: 0, budget: &budget)
        #expect(metric.records.isEmpty && metric.distance == 0)
        try metric.append(StrokeQuadCurve(start: .zero, control: SIMD2(0, Float(1).nextUp), end: .zero), curveIndex: 0, budget: &budget)
        #expect(metric.records.map(\.parameter) == [0.5, 1])
        #expect(metric.records.map { $0.distance.bitPattern } == [0x3F000001, 0x3F800001])
    }

    /// 非共线Quad以实际半切子曲线测长，两条独立平方根期望锁定Float累计。
    @Test func curvedQuadMeasuresChoppedGeometry() throws {
        var budget = try GeometryBudget()
        var metric = StrokeDashMetric()
        try metric.append(StrokeQuadCurve(start: .zero, control: SIMD2(0, 4), end: SIMD2(4, 4)), curveIndex: 3, budget: &budget)
        #expect(metric.records.map(\.parameter) == [0.5, 1])
        #expect(metric.records.map { $0.distance.bitPattern } == [0x404A62C2, 0x40CA62C2])
        #expect(metric.records.map(\.curve) == [3, 3])
    }

    /// 共线Quad的叶长1和3遇大前缀按ties-to-even吞没；不能用Double补回或擅自增加curveIndex。
    @Test func largePrefixSwallowsLeavesWithoutChangingOwnership() throws {
        for value: (Float, [Float], [UInt32]) in [
            (16_777_216, [1], [0x4B800002]),
            (16_777_218, [0.5, 1], [0x4B800002, 0x4B800004]),
            (67_108_864, [], [])
        ] {
            var budget = try GeometryBudget()
            var metric = StrokeDashMetric()
            try metric.appendLine(from: .zero, to: SIMD2(value.0, 0), curveIndex: 0, budget: &budget)
            try metric.append(StrokeQuadCurve(start: .zero, control: .zero, end: SIMD2(4, 0)), curveIndex: 1, budget: &budget)
            let suffix = metric.records.dropFirst()
            #expect(suffix.map(\.parameter) == value.1)
            #expect(suffix.map { $0.distance.bitPattern } == value.2)
            #expect(suffix.allSatisfy { $0.curve == 1 })
            if suffix.isEmpty {
                #expect(metric.distance == value.0)
                // 完全被吞的曲线没有提交，下一条合法复用相同的外层索引。
                try metric.appendLine(from: .zero, to: SIMD2(8, 0), curveIndex: 1, budget: &budget)
                #expect(metric.records.last?.curve == 1 && metric.distance == 67_108_872)
            }
        }
    }

    /// 放大四分圆按原Conic全局参数求值，半径8的不对称累计能识别错误的子曲线重新参数化。
    @Test func conicRecordsKeepOriginalGlobalParameterization() throws {
        for value: (Float, [Float], [UInt32]) in [
            (1, [1], [0x3FB504F3]),
            (2, [1], [0x403504F3]),
            (4, [0.5, 1], [0x4043EF15, 0x40C3EF15]),
            (8, [0.25, 0.5, 0.75, 1], [0x403FDCC1, 0x40C7C42C, 0x4117CCFC, 0x4147C42D])
        ] {
            var budget = try GeometryBudget()
            var metric = StrokeDashMetric()
            try metric.append(quarter(radius: value.0), curveIndex: 11, budget: &budget)
            #expect(metric.records.map(\.parameter) == value.1)
            #expect(metric.records.map { $0.distance.bitPattern } == value.2)
            #expect(metric.records.allSatisfy { $0.curve == 11 })
        }
    }

    /// Conic的中点偏差等于0.5时接受整弦，控制点下一Float则触发源全局半参数分段。
    @Test func conicDeviationUsesStrictThreshold() throws {
        for value: (Float, [Float], [UInt32]) in [
            (1.5, [1], [0x40000000]),
            (Float(1.5).nextUp, [0.5, 1], [0x3F8F1BBD, 0x400F1BBD])
        ] {
            var budget = try GeometryBudget()
            var metric = StrokeDashMetric()
            let curve = try StrokeConicCurve(start: .zero, control: SIMD2(1, value.0), end: SIMD2(2, 0), weight: 0.5)
            try metric.append(curve, curveIndex: 0, budget: &budget)
            #expect(metric.records.map(\.parameter) == value.1)
            #expect(metric.records.map { $0.distance.bitPattern } == value.2)
        }
    }

    /// 根Conic测量用原末点，不能用Horner端点的一ULP差改写整条叶弦长度。
    @Test func conicRootEndpointsUseStoredGeometry() throws {
        var budget = try GeometryBudget()
        var metric = StrokeDashMetric()
        let curve = try StrokeConicCurve(start: .zero, control: SIMD2(0.25, 0), end: SIMD2(-0.25, 0),
                                         weight: Float(bitPattern: 0x3F3504F3))
        // 此例是已独立核对的(0,4,-4)按2^-4缩小；Horner舍入仍在，但根偏差已小于0.5。
        #expect(try curve.position(at: 1, budget: &budget).x.bitPattern == 0xBE800001)
        try metric.append(curve, curveIndex: 2, budget: &budget)
        #expect(metric.records.count == 1 && metric.records[0].parameter == 1)
        #expect(metric.distance.bitPattern == 0x3E800000)
    }

    /// 单位圆四段共享Float累计，源码总长小于5.8；不能先转Cubic改变dash是否出现缺口。
    @Test func fourQuarterCircleKeepsSourceContourLength() throws {
        let points: [SIMD2<Float>] = [SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1), SIMD2(-1, 1),
                                      SIMD2(-1, 0), SIMD2(-1, -1), SIMD2(0, -1), SIMD2(1, -1), SIMD2(1, 0)]
        var budget = try GeometryBudget()
        var metric = StrokeDashMetric()
        for index in 0..<4 {
            let curve = try StrokeConicCurve(start: points[index * 2], control: points[index * 2 + 1],
                                             end: points[index * 2 + 2], weight: Float(bitPattern: 0x3F3504F3))
            try metric.append(curve, curveIndex: index, budget: &budget)
        }
        #expect(metric.records.map(\.curve) == [0, 1, 2, 3])
        #expect(metric.records.map(\.parameter) == [1, 1, 1, 1])
        #expect(metric.distance.bitPattern == 0x40B504F3)
        #expect(metric.distance < 5.8)
    }

    /// Line、Cubic、Quad与Conic使用同一累计表，索引来自调用方而不是记录数量。
    @Test func allCurveKindsShareOneMetric() throws {
        var budget = try GeometryBudget()
        var metric = StrokeDashMetric()
        try metric.appendLine(from: .zero, to: SIMD2(1, 0), curveIndex: 4, budget: &budget)
        try metric.appendCubic(from: .zero, firstControl: SIMD2(1, 0), secondControl: SIMD2(2, 0),
                               to: SIMD2(3, 0), curveIndex: 9, budget: &budget)
        try metric.append(StrokeQuadCurve(start: .zero, control: .zero, end: SIMD2(2, 0)), curveIndex: 12, budget: &budget)
        try metric.append(quarter(radius: 1), curveIndex: 16, budget: &budget)
        #expect(metric.records.map(\.curve) == [4, 9, 12, 16])
        #expect(metric.records.map(\.parameter) == [1, 1, 1, 1])
        #expect(metric.records.map(\.distance) == [1, 4, 6, Float(6) + Float(bitPattern: 0x3FB504F3)])
    }

    /// Quad叶弦的Float平方溢出仍可按源Double回退成功；不改变Float差值或累计的精度。
    @Test func quadSquaredOverflowUsesSharedLengthFallback() throws {
        var budget = try GeometryBudget()
        var metric = StrokeDashMetric()
        let curve = try StrokeQuadCurve(start: .zero, control: SIMD2(5e19, 0), end: SIMD2(1e20, 0))
        try metric.append(curve, curveIndex: 0, budget: &budget)
        #expect(metric.records.count == 1 && metric.records[0].parameter == 1)
        #expect(metric.distance.bitPattern == 0x60AD78EC)
    }

    /// 一条Conic全部被大前缀吞没时没有新记录，既有距离和外层归属不变。
    @Test func conicCanBeEntirelySwallowed() throws {
        var budget = try GeometryBudget()
        var metric = StrokeDashMetric()
        try metric.appendLine(from: .zero, to: SIMD2(33_554_432, 0), curveIndex: 0, budget: &budget)
        try metric.append(quarter(radius: 1), curveIndex: 1, budget: &budget)
        #expect(metric.distance == 33_554_432 && metric.records.count == 1)
        #expect(metric.records[0].curve == 0)
    }

    /// 只构造源四分圆输入，记录期望由独立逐运算Float核算固定在各测试中。
    private func quarter(radius: Float) throws -> StrokeConicCurve {
        try StrokeConicCurve(start: SIMD2(radius, 0), control: SIMD2(radius, radius),
                             end: SIMD2(0, radius), weight: Float(bitPattern: 0x3F3504F3))
    }
}
