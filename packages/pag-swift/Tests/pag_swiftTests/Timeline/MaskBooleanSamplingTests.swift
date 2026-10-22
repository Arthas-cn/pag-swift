import Testing
@testable import pag_swift

/// 多路径普通蒙版的源顺序、空verb、父合成帧、分流与预算；此组不宣称已接Metal。
struct MaskBooleanSamplingTests {
    /// 两个有效路径按编码顺序保留各自对象、模式和反向位，后续布尔的远场同时变化。
    @Test func orderedTermsKeepEachSourceIdentityAndOutsideTruth() throws {
        let first = try ShapePathFixtures.square(10)
        let second = try ShapePathFixtures.square(20)
        let value = try #require(try sample([
            MaskTestSupport.mask(.init(constant: first), mode: .subtract),
            MaskTestSupport.mask(.init(constant: second), mode: .difference, inverted: true)
        ]))
        guard case .expression(let expression) = value else {
            Issue.record("两条有效源路径必须保留完整Boolean表达式")
            return
        }
        #expect(expression.terms.count == 2)
        #expect(expression.terms[0].path === first && expression.terms[0].mode == .subtract)
        #expect(expression.terms[1].path === second && expression.terms[1].mode == .difference)
        #expect(expression.terms[1].isInverted)
        #expect(expression.isInverted == false)
        #expect(expression.estimatedBytes == 128 + first.estimatedBytes + second.estimatedBytes + 96)
    }

    /// None和开放路径不占首位，仅Close仍占首位并留给后续PathKit空结果门禁。
    @Test func sourceClosureDeterminesFirstEffectiveTerm() throws {
        let square = try ShapePathFixtures.square(10)
        let onlyClose = try SourcePath(verbs: [.close], points: [])
        let open = try SourcePath(verbs: [.move, .line], points: [.zero, .one])
        let value = try #require(try sample([
            MaskTestSupport.mask(.init(constant: square), mode: .none),
            MaskTestSupport.mask(.init(constant: open)),
            MaskTestSupport.mask(.init(constant: onlyClose), mode: .difference),
            MaskTestSupport.mask(.init(constant: square), mode: .subtract)
        ]))
        guard case .expression(let expression) = value else {
            Issue.record("仅Close虽无verb仍占据首项")
            return
        }
        #expect(expression.terms.count == 2)
        #expect(expression.terms[0].path === onlyClose)
        #expect(expression.terms[1].mode == .subtract)
        #expect(expression.isInverted == false)
        #expect(try sample([MaskTestSupport.mask(.init(constant: onlyClose)),
                            MaskTestSupport.mask(.init(constant: open))]) == nil)
    }

    /// 两条动态路径按调用方给出的父合成帧独立采样，不共享可变游标或使用图层局部时间。
    @Test func animatedTermsSampleSelectedCompositionFrame() throws {
        let small = try ShapePathFixtures.square(10)
        let large = try ShapePathFixtures.square(30)
        let track = try SourceProperty(keyframes: [SourceKeyframe(startFrame: 10, endFrame: 30,
            startValue: small, endValue: large, easing: .linear, spatialCurve: nil)])
        let fixed = MaskTestSupport.mask(.init(constant: small), mode: .add)
        let changing = MaskTestSupport.mask(track, mode: .intersect)
        let value = try #require(try sample([fixed, changing], at: 20))
        guard case .expression(let expression) = value else {
            Issue.record("两条有效路径应生成多项表达式")
            return
        }
        #expect(expression.terms[0].path === small)
        #expect(expression.terms[1].path !== small && expression.terms[1].path !== large)
        #expect(expression.terms[1].path.points[1].x == 30)
        let endpoint = try #require(try sample([fixed, changing], at: 30))
        guard case .expression(let end) = endpoint else {
            Issue.record("末帧仍有两条路径")
            return
        }
        #expect(end.terms[1].path === large)
    }

    /// 动画段内空路径使后项重新成为首项，端点闭合时恢复两项及原始源顺序。
    @Test func animatedClosureChangesFirstTermAtParentFrame() throws {
        let empty = try SourcePath(verbs: [], points: [])
        let square = try ShapePathFixtures.square(10)
        let track = try SourceProperty(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 10,
            startValue: empty, endValue: square, easing: .linear, spatialCurve: nil)])
        let masks = [MaskTestSupport.mask(track, mode: .add),
                     MaskTestSupport.mask(.init(constant: square), mode: .subtract)]
        let middle = try #require(try sample(masks, at: 5))
        guard case .path(let one) = middle else {
            Issue.record("段内空路径应让Subtract成为首项")
            return
        }
        #expect(one.path === square && one.isInverted)
        let endpoint = try #require(try sample(masks, at: 10))
        guard case .expression(let two) = endpoint else {
            Issue.record("闭合端点应恢复原始两项顺序")
            return
        }
        #expect(two.terms.count == 2)
        #expect(two.terms[0].path === square && two.terms[0].mode == .add)
        #expect(two.terms[1].mode == .subtract && two.isInverted == false)
    }

    /// 全层羽化优先于跳过项；有效项扩张保留帧值，None扩张不触发描边。
    @Test func branchAndExpansionGatesPrecedeBooleanPublication() throws {
        let path = try ShapePathFixtures.square(10)
        let base = MaskTestSupport.mask(.init(constant: path))
        let ignoredExpansion = MaskTestSupport.mask(.init(constant: path), mode: .none,
                                                    expansion: .init(constant: 3))
        #expect(try sample([base, ignoredExpansion]) != nil)
        let feather = MaskTestSupport.mask(.init(constant: path), mode: .none,
                                           feather: .init(constant: .zero))
        #expect(throws: PAGError.unsupportedFeature("featherMask")) {
            try sample([base, feather])
        }
        let expansion = MaskTestSupport.mask(.init(constant: path), expansion: .init(constant: 3))
        let value = try #require(try sample([base, expansion]))
        guard case .expression(let expression) = value else {
            Issue.record("有效扩张路径必须保留在Boolean表达式中")
            return
        }
        #expect(expression.terms.count == 2 && expression.terms[1].expansion == 3)
    }

    /// 单路径扩张也应走表达式；动画按父合成帧取Float值，恰为零时回到单路径缓存。
    @Test func singlePathExpansionTracksSelectedParentFrame() throws {
        let path = try ShapePathFixtures.square(10)
        let expansion = try SourceProperty(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 10,
            startValue: 0.0, endValue: 4.0, easing: .linear, spatialCurve: nil)])
        let mask = MaskTestSupport.mask(.init(constant: path), expansion: expansion)
        let start = try #require(try sample([mask], at: 0))
        guard case .path(let plain) = start else { Issue.record("零扩张应使用原路径"); return }
        #expect(plain.path === path)
        let middle = try #require(try sample([mask], at: 5))
        guard case .expression(let value) = middle else { Issue.record("非零扩张须保留帧值"); return }
        #expect(value.terms.count == 1 && value.terms[0].path === path)
        #expect(value.terms[0].expansion == 2)
        let end = try #require(try sample([mask], at: 10))
        guard case .expression(let last) = end else { Issue.record("端点扩张仍须生效"); return }
        #expect(last.terms[0].expansion == 4)
        var measured = FramePlanBudget(limit: 1_000_000)
        #expect(try MaskPreparation.orderedPaths([mask], at: 5, budget: &measured) != nil)
        var exact = FramePlanBudget(limit: measured.used)
        #expect(try MaskPreparation.orderedPaths([mask], at: 5, budget: &exact) != nil)
        var tiny = FramePlanBudget(limit: measured.used - 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try MaskPreparation.orderedPaths([mask], at: 5, budget: &tiny)
        }
    }

    /// 极小负扩张按同源差集成为零verb无裁剪；较大值与宽度溢出分别进入表达式和失败。
    @Test func hairlineNegativeAndOverflowDoNotPublishWrongMask() throws {
        let path = try ShapePathFixtures.square(10)
        let hairline = MaskTestSupport.mask(.init(constant: path), expansion: .init(constant: -1.0 / 8192))
        #expect(try sample([hairline]) == nil)
        let wider = MaskTestSupport.mask(.init(constant: path), expansion: .init(constant: -1.0 / 8000))
        let value = try #require(try sample([wider]))
        guard case .expression(let expression) = value else { Issue.record("阈值外须扩张"); return }
        #expect(expression.terms[0].expansion < 0)
        let overflow = MaskTestSupport.mask(.init(constant: path),
                                             expansion: .init(constant: Double(Float.greatestFiniteMagnitude)))
        #expect(throws: PAGError.resourceLimitExceeded("maximumStrokeMagnitude")) {
            try sample([overflow])
        }
    }

    /// 首项负hairline归一化为空verb后，连续交集/差集仍撤销裁剪；并集或首项反向不得误跳过。
    @Test func negativeHairlineZeroVerbChainKeepsPathKitBranch() throws {
        let path = try ShapePathFixtures.square(10)
        let hairline = MaskTestSupport.mask(.init(constant: path),
                                            expansion: .init(constant: -1.0 / 8192))
        for mode in [SourceMaskMode.intersect, .darken, .subtract] {
            let chain = [hairline, MaskTestSupport.mask(.init(constant: path), mode: mode)]
            #expect(try sample(chain) == nil)
        }
        let union = [hairline, MaskTestSupport.mask(.init(constant: path), mode: .add)]
        #expect(try sample(union) != nil)
        let inverted = [MaskTestSupport.mask(.init(constant: path), inverted: true,
                                              expansion: .init(constant: -1.0 / 8192)),
                        MaskTestSupport.mask(.init(constant: path), mode: .intersect)]
        #expect(try sample(inverted) != nil)
    }

    /// 完整多项来源成本精确上限可通过，少一字节和预取消均不发布部分表达式。
    @Test func multipleSourceBudgetAndCancellation() async throws {
        let path = try ShapePathFixtures.square(10)
        let masks = [MaskTestSupport.mask(.init(constant: path)),
                     MaskTestSupport.mask(.init(constant: path), mode: .difference)]
        var measured = FramePlanBudget(limit: 1_000_000)
        let result = try MaskPreparation.orderedPaths(masks, at: 0, budget: &measured)
        #expect(result != nil)
        var exact = FramePlanBudget(limit: measured.used)
        #expect(try MaskPreparation.orderedPaths(masks, at: 0, budget: &exact) != nil)
        var tiny = FramePlanBudget(limit: measured.used - 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try MaskPreparation.orderedPaths(masks, at: 0, budget: &tiny)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var budget = FramePlanBudget(limit: 1_000_000)
            return try MaskPreparation.orderedPaths(masks, at: 0, budget: &budget)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 默认预算下读取内部普通蒙版，不创建计划或GPU资源。
    private func sample(_ masks: [SourceMask], at frame: Int64 = 0) throws -> SampledMaskValue? {
        var budget = FramePlanBudget(limit: 64 * 1024 * 1024)
        return try MaskPreparation.orderedPaths(masks, at: frame, budget: &budget)
    }
}
