import Testing
@testable import pag_swift

/// 普通蒙版的分支、顺序、空路径与有界准备；不把内部单项通过当成整文件绘制支持。
struct MaskPreparationTests {
    /// 所有非None首项均直接选路径，只有Subtract翻转原始反向位。
    @Test(arguments: [SourceMaskMode.add, .subtract, .intersect, .lighten, .darken, .difference, .accumulate], [false, true])
    func firstModeKeepsPathAndCorrectInverse(mode: SourceMaskMode, inverted: Bool) throws {
        let path = try ShapePathFixtures.square(20)
        let mask = MaskTestSupport.mask(.init(constant: path), mode: mode, inverted: inverted)
        let value = try #require(try MaskTestSupport.sample([mask]))
        #expect(value.path === path)
        #expect(value.isInverted == (inverted != (mode == .subtract)))
    }

    /// 空列表、空路径、None及开放路径都没有clip；仅Close的TGFX零verb也不能创建空clip。
    @Test func skippedAndNormalizedEmptyPathsHaveNoClip() throws {
        #expect(try MaskTestSupport.sample([]) == nil)
        for path in [try SourcePath(verbs: [], points: []),
                     try SourcePath(verbs: [.close, .close], points: []),
                     try SourcePath(verbs: [.move, .line], points: [.zero, .one])] {
            for inverted in [false, true] {
                #expect(try MaskTestSupport.sample([MaskTestSupport.mask(.init(constant: path), inverted: inverted)]) == nil)
            }
        }
        let path = try ShapePathFixtures.square(20)
        #expect(try MaskTestSupport.sample([MaskTestSupport.mask(.init(constant: path), mode: .none)]) == nil)
    }

    /// Move+Close与共线闭合路径非空verb但无面积，仍保留正反向裁剪身份。
    @Test func zeroAreaPathsRemainClips() throws {
        let paths = [try SourcePath(verbs: [.move, .close], points: [.zero]),
                     try SourcePath(verbs: [.move, .line, .line, .close], points: [.zero, .one, ScenePoint(x: 2, y: 2)])]
        for path in paths {
            for inverted in [false, true] {
                let result = try #require(try MaskTestSupport.sample([MaskTestSupport.mask(.init(constant: path), inverted: inverted)]))
                #expect(result.path === path && result.isInverted == inverted)
                #expect(try MaskTestSupport.mesh(result.path).vertices.isEmpty)
            }
        }
    }

    /// None/open不消耗首项，但仅Close及Move+Close会消耗，不能把之后Subtract误当首项。
    @Test func firstEffectivePathUsesSourceClosureNotArea() throws {
        let square = try ShapePathFixtures.square(20)
        let skipped = MaskTestSupport.mask(.init(constant: square), mode: .none)
        let open = MaskTestSupport.mask(.init(constant: try SourcePath(verbs: [.move], points: [.zero])))
        let subtract = MaskTestSupport.mask(.init(constant: square), mode: .subtract)
        #expect(try MaskTestSupport.sample([skipped, open, subtract])?.isInverted == true)
        for first in [try SourcePath(verbs: [.close], points: []),
                      try SourcePath(verbs: [.move, .close], points: [.zero]), square] {
            #expect(throws: PAGError.unsupportedFeature("multipleMaskPaths")) {
                try MaskTestSupport.sample([MaskTestSupport.mask(.init(constant: first)), subtract])
            }
        }
    }

    /// 全层羽化资格优先于可见路径过滤和多路径门禁，即使后面的None项才携带该属性。
    @Test func featherSelectionPrecedesEverySkip() throws {
        let path = try ShapePathFixtures.square(20)
        let ordinary = MaskTestSupport.mask(.init(constant: path))
        let animated = try SourceProperty<UInt8>(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 10,
            startValue: 255, endValue: 255, easing: .linear, spatialCurve: nil)])
        let variants = [MaskTestSupport.mask(.init(constant: path), mode: .none, feather: .init(constant: .zero)),
            MaskTestSupport.mask(.init(constant: path), mode: .none, opacity: animated),
            MaskTestSupport.mask(.init(constant: try SourcePath(verbs: [], points: [])), opacity: .init(constant: 254))]
        for variant in variants {
            #expect(throws: PAGError.unsupportedFeature("featherMask")) {
                try MaskTestSupport.sample([ordinary, ordinary, variant])
            }
        }
    }

    /// 有效路径仅接纳恒零扩张，零值动画也拒绝；None/open仍按源码在读取expansion之前跳过。
    @Test func expansionGateDoesNotEvaluateSkippedMasks() throws {
        let path = try ShapePathFixtures.square(20)
        let animated = try SourceProperty<Double>(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 10,
            startValue: 0, endValue: 0, easing: .linear, spatialCurve: nil)])
        for expansion in [SourceProperty(constant: -2.0), .init(constant: 3.0), animated] {
            #expect(throws: PAGError.unsupportedFeature("maskExpansion")) {
                try MaskTestSupport.sample([MaskTestSupport.mask(.init(constant: path), expansion: expansion)])
            }
            #expect(try MaskTestSupport.sample([MaskTestSupport.mask(.init(constant: path), mode: .none, expansion: expansion)]) == nil)
        }
    }

    /// 常量路径每次保活均收完整成本；精确上限通过，少一字节及预取消均不产生结果。
    @Test func retainedPathBudgetAndCancellation() async throws {
        let path = try ShapePathFixtures.square(20)
        let mask = MaskTestSupport.mask(.init(constant: path))
        // 两次列表访问、首次非Close检查、返回值外壳和源路径；常量复用不免除留存计费。
        let cost = 64 + 8 + 128 + path.estimatedBytes
        var exact = FramePlanBudget(limit: cost)
        #expect(try MaskPreparation.singlePath([mask], at: 0, budget: &exact)?.path === path)
        #expect(exact.used == cost)
        var tiny = FramePlanBudget(limit: cost - 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try MaskPreparation.singlePath([mask], at: 0, budget: &tiny)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MaskTestSupport.sample([])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
