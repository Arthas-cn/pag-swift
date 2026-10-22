import Testing
@testable import pag_swift

/// 羽化蒙版的PathKit点包围盒、矩形扩张、特殊总体范围与非矩形门禁。
struct FeatherMaskBoundsTests {
    /// None项不绘制却扩展总体右/下边界；左/上仍从零开始再按10%外扩。
    @Test func skippedItemStillChangesOverallBounds() throws {
        let square = try ShapePathFixtures.square(20)
        let remote = try SourcePath(verbs: [.move, .line, .line, .line, .close], points: [
            ScenePoint(x: 60, y: 40), ScenePoint(x: 80, y: 40),
            ScenePoint(x: 80, y: 50), ScenePoint(x: 60, y: 50)])
        let masks = [MaskTestSupport.mask(.init(constant: square)),
                     MaskTestSupport.mask(.init(constant: remote), mode: .none,
                                          opacity: .init(constant: 128))]
        let result = try Self.measure(masks)
        #expect(result.items == [try RenderBounds(left: 10, top: 10, right: 30, bottom: 30),
                                 try RenderBounds(left: 60, top: 40, right: 80, bottom: 50)])
        #expect(result.overall == (try RenderBounds(left: -8, top: -5, right: 88, bottom: 55)))
    }

    /// 三次曲线使用两个控制点的原Float坐标求范围，不用曲线真实极值的紧边界。
    @Test func cubicControlPointsEnterPathBounds() throws {
        let curve = try SourcePath(verbs: [.move, .cubic, .close], points: [
            ScenePoint(x: 10, y: 10), ScenePoint(x: 90, y: 80),
            ScenePoint(x: -40, y: 70), ScenePoint(x: 20, y: 20)])
        let result = try Self.measure([MaskTestSupport.mask(.init(constant: curve),
                                                        opacity: .init(constant: 128))])
        #expect(result.items[0] == (try RenderBounds(left: -40, top: 10, right: 90, bottom: 80)))
        #expect(result.overall == (try RenderBounds(left: -9, top: -8, right: 99, bottom: 88)))
    }

    /// C++无f后缀的0.1先按Double相乘再转Float；固定上游算式的Float位型避免1 ulp漂移。
    @Test func doubleLiteralOutsetKeepsExactFloatBits() throws {
        let width = Double(Float(bitPattern: 0x3b18a223))
        let path = try SourcePath(verbs: [.move, .line, .line, .close], points: [
            .zero, ScenePoint(x: width, y: 0), ScenePoint(x: width, y: width)])
        let result = try Self.measure([MaskTestSupport.mask(.init(constant: path),
                                                        opacity: .init(constant: 128))])
        // 独立C++探针以width * 0.1传给float参数，再由Rect::outset执行Float加减。
        #expect(Float(result.overall.left).bitPattern == 0xb974369e)
        #expect(Float(result.overall.top).bitPattern == 0xb974369e)
        #expect(Float(result.overall.right).bitPattern == 0x3b27e58d)
        #expect(Float(result.overall.bottom).bitPattern == 0x3b27e58d)
    }

    /// 全负坐标不把总体left/top移到负值；空点列表为原点零范围，单Move点保留该点。
    @Test func negativeAndDegeneratePathsKeepSourceBoundsRule() throws {
        let negative = try SourcePath(verbs: [.move, .line, .line, .line, .close], points: [
            ScenePoint(x: -40, y: -30), ScenePoint(x: -10, y: -30),
            ScenePoint(x: -10, y: -5), ScenePoint(x: -40, y: -5)])
        let negativeResult = try Self.measure([MaskTestSupport.mask(.init(constant: negative),
                                                                 opacity: .init(constant: 128))])
        #expect(negativeResult.items[0] == (try RenderBounds(left: -40, top: -30, right: -10, bottom: -5)))
        let small = Float.leastNormalMagnitude
        #expect(negativeResult.overall.left == Double(-(small * 0.1)))
        #expect(negativeResult.overall.right == Double(small + small * 0.1))

        let empty = try SourcePath(verbs: [.close], points: [])
        let point = try SourcePath(verbs: [.move, .close], points: [ScenePoint(x: 7, y: 9)])
        let result = try Self.measure([MaskTestSupport.mask(.init(constant: empty),
                                                         opacity: .init(constant: 128)),
                                       MaskTestSupport.mask(.init(constant: point))])
        #expect(result.items[0] == (try RenderBounds(left: 0, top: 0, right: 0, bottom: 0)))
        #expect(result.items[1] == (try RenderBounds(left: 7, top: 9, right: 7, bottom: 9)))
    }

    /// 闭合矩形正负扩张使用PathKit专门strokeRect边界；None项仍影响总体范围。
    @Test func rectangleExpansionMeasuresBeforeDrawFiltering() throws {
        let square = try ShapePathFixtures.square(20)
        let positive = MaskTestSupport.mask(.init(constant: square), mode: .none,
                                            opacity: .init(constant: 128),
                                            expansion: .init(constant: 2))
        let negative = MaskTestSupport.mask(.init(constant: square),
                                            opacity: .init(constant: 128),
                                            expansion: .init(constant: -2))
        let result = try Self.measure([positive, negative])
        #expect(result.items == [try RenderBounds(left: 8, top: 8, right: 32, bottom: 32),
                                 try RenderBounds(left: 12, top: 12, right: 28, bottom: 28)])
        let pad = Float(Double(Float(32)) * 0.1)
        #expect(result.overall == (try RenderBounds(left: Double(-pad), top: Double(-pad),
            right: Double(Float(32) + pad), bottom: Double(Float(32) + pad))))
    }

    /// hairline正并保留原矩形、负差消空；负宽覆盖整矩形也没有局部绘制范围。
    @Test func rectangleHairlineAndExhaustionKeepZeroBounds() throws {
        let square = try ShapePathFixtures.square(20)
        let tiny = 1.0 / 8192.0
        let result = try Self.measure([
            MaskTestSupport.mask(.init(constant: square), opacity: .init(constant: 128),
                                 expansion: .init(constant: tiny)),
            MaskTestSupport.mask(.init(constant: square), opacity: .init(constant: 128),
                                 expansion: .init(constant: -tiny)),
            MaskTestSupport.mask(.init(constant: square), opacity: .init(constant: 128),
                                 expansion: .init(constant: -10))
        ])
        #expect(result.items[0] == (try RenderBounds(left: 10, top: 10, right: 30, bottom: 30)))
        let empty = try RenderBounds(left: 0, top: 0, right: 0, bottom: 0)
        #expect(result.items[1] == empty && result.items[2] == empty)
    }

    /// 非矩形非零扩张仍不能用原始控制点代替PathOp结果；隐式指令同样拒绝伪测。
    @Test func unknownFinalPathPointsFailExplicitly() throws {
        let triangle = try SourcePath(verbs: [.move, .line, .line, .close], points: [
            ScenePoint(x: 10, y: 10), ScenePoint(x: 30, y: 10), ScenePoint(x: 20, y: 30)])
        let expanded = MaskTestSupport.mask(.init(constant: triangle), mode: .none,
                                            opacity: .init(constant: 128),
                                            expansion: .init(constant: 2))
        #expect(throws: PAGError.unsupportedFeature("featherMaskExpansionBounds")) {
            try Self.measure([expanded])
        }
        let implicit = try SourcePath(verbs: [.line, .close], points: [ScenePoint(x: 7, y: 9)])
        #expect(throws: PAGError.unsupportedFeature("featherMaskPathSequence")) {
            try Self.measure([MaskTestSupport.mask(.init(constant: implicit),
                                                   opacity: .init(constant: 128))])
        }
    }

    /// 测量遍历按点计费；恰好预算成功，少一字节及预取消均不得返回部分范围。
    @Test func budgetAndCancellation() async throws {
        let mask = MaskTestSupport.mask(.init(constant: try ShapePathFixtures.square(20)),
                                        opacity: .init(constant: 128))
        var sampling = FramePlanBudget(limit: 1_000_000)
        let value = try #require(try FeatherMaskSampling.sample([mask], at: 0, budget: &sampling))
        var measured = FramePlanBudget(limit: 1_000_000)
        #expect(try FeatherMaskBounds.measure(value, budget: &measured).items.count == 1)
        var exact = FramePlanBudget(limit: measured.used)
        #expect(try FeatherMaskBounds.measure(value, budget: &exact).items.count == 1)
        var tiny = FramePlanBudget(limit: measured.used - 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try FeatherMaskBounds.measure(value, budget: &tiny)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var budget = FramePlanBudget(limit: 1_000_000)
            return try FeatherMaskBounds.measure(value, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 用正式采样器构造该父帧的全部项，再单独计量纯bounds工作。
    private static func measure(_ masks: [SourceMask]) throws -> MeasuredFeatherMask {
        var sampling = FramePlanBudget(limit: 1_000_000)
        let value = try #require(try FeatherMaskSampling.sample(masks, at: 0, budget: &sampling))
        var bounds = FramePlanBudget(limit: 1_000_000)
        return try FeatherMaskBounds.measure(value, budget: &bounds)
    }
}
