import Testing
@testable import pag_swift

/// 蒙版采样沿父合成帧和既有Float属性内核，不保存跨实例或跨任务的可变游标。
struct MaskAnimationTests {
    /// travel真实Bezier的父合成45/50帧对应独立Float金值，不能减去图层起点后再次采样。
    @Test func realTravelFramesMatchIndependentFloatValues() throws {
        let data = try PAGFixtures.data(named: "travel.pag").subdata(in: 2_172..<2_210)
        let source = try MaskFixtures.read(data).mask
        // 独立Python逐操作Float32探针重建上游0.005曲线折线，未调用Swift属性求值器。
        for (frame, bits): (Int64, UInt32) in [(50, 0x428BE869), (45, 0x414759C0), (50, 0x428BE869)] {
            let result = try #require(try MaskTestSupport.sample([source], at: frame))
            #expect(Float(result.path.points[2].x).bitPattern == bits)
            #expect(result.path.points[2].y == 45.25 && result.isInverted == false)
        }
    }

    /// 常量、轨道外端点和Hold保持原路径身份；内部Linear按父帧插值且并发乱序不互相污染。
    @Test func endpointIdentityHoldAndConcurrentSampling() async throws {
        let first = try ShapePathFixtures.square(10)
        let last = try ShapePathFixtures.square(30)
        let linear = try SourceProperty(keyframes: [SourceKeyframe(startFrame: -10, endFrame: 10,
            startValue: first, endValue: last, easing: .linear, spatialCurve: nil)])
        let mask = MaskTestSupport.mask(linear)
        #expect(try MaskTestSupport.sample([mask], at: -20)?.path === first)
        #expect(try MaskTestSupport.sample([mask], at: 20)?.path === last)
        let hold = try SourceProperty(keyframes: [SourceKeyframe(startFrame: -10, endFrame: 10,
            startValue: first, endValue: last, easing: .hold, spatialCurve: nil)])
        #expect(try MaskTestSupport.sample([MaskTestSupport.mask(hold)], at: 0)?.path === first)
        #expect(try MaskTestSupport.sample([MaskTestSupport.mask(hold)], at: 10)?.path === last)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for frame: Int64 in [9, -9, 0, -5, 5, 9, -9] {
                group.addTask {
                    let result = try #require(try MaskTestSupport.sample([mask], at: frame))
                    #expect(result.path !== first && result.path !== last)
                    #expect(result.path.points[1].x == Double(30 + frame))
                }
            }
            try await group.waitForAll()
        }
    }

    /// 任一空端点使段内插值为空，端点仍可闭合；因此有效数量必须按本帧而非initialValue判断。
    @Test func animatedClosureChangesEffectiveCount() throws {
        let empty = try SourcePath(verbs: [], points: [])
        let square = try ShapePathFixtures.square(20)
        let property = try SourceProperty(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 10,
            startValue: empty, endValue: square, easing: .linear, spatialCurve: nil)])
        let animated = MaskTestSupport.mask(property)
        let subtract = MaskTestSupport.mask(.init(constant: square), mode: .subtract)
        #expect(try MaskTestSupport.sample([animated], at: 5) == nil)
        #expect(try MaskTestSupport.sample([animated], at: 10)?.path === square)
        #expect(try MaskTestSupport.sample([animated, subtract], at: 5)?.isInverted == true)
        #expect(throws: PAGError.unsupportedFeature("multipleMaskPaths")) {
            try MaskTestSupport.sample([animated, subtract], at: 10)
        }
    }

    /// 真实无扩展名15的两个Linear轨道中点必须逐坐标按Float求中值，并保留完整verbs。
    @Test func extensionlessLinearMidpoints() throws {
        let data = try PAGFixtures.data(named: "15")
        for range in [153_193..<153_299, 153_998..<154_127] {
            let mask = try MaskFixtures.read(data.subdata(in: range)).mask
            let key = try #require(mask.path.keyframes.first)
            let sampled = try #require(try MaskTestSupport.sample([mask], at: 15))
            #expect(sampled.path.verbs == key.startValue.verbs)
            for index in sampled.path.points.indices {
                let start = key.startValue.points[index], end = key.endValue.points[index]
                let x = Float(start.x) + (Float(end.x) - Float(start.x)) * 0.5
                let y = Float(start.y) + (Float(end.y) - Float(start.y)) * 0.5
                #expect(sampled.path.points[index] == ScenePoint(x: Double(x), y: Double(y)))
            }
        }
    }

    /// 动态路径实际分配另计预算，精确费用可重复通过，减少一字节必须原子失败。
    @Test func interpolatedPathBudgetIsNotStaticCost() throws {
        let mask = MaskTestSupport.mask(try ShapePathFixtures.track())
        var measure = FramePlanBudget(limit: 1_000_000)
        let result = try #require(try MaskPreparation.singlePath([mask], at: 10, budget: &measure))
        let staticCost = 64 + 8 + 128 + result.path.estimatedBytes
        #expect(measure.used > staticCost)
        var exact = FramePlanBudget(limit: measure.used)
        #expect(try MaskPreparation.singlePath([mask], at: 10, budget: &exact) != nil)
        var tiny = FramePlanBudget(limit: measure.used - 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try MaskPreparation.singlePath([mask], at: 10, budget: &tiny)
        }
    }
}
