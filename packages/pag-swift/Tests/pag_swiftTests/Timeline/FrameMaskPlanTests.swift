import Metal
import Testing
@testable import pag_swift

/// 验证普通单路径与有序多路径蒙版在场景计划中的采样帧、矩阵和成对作用域。
struct FrameMaskPlanTests {
    /// 图层start不改变蒙版采样帧；正向路径必须包住该层实际内容绘制。
    @Test func solidMaskUsesCompositionFrameAndOwnTransform() async throws {
        let first = try square(at: 0)
        let last = try square(at: 20)
        let path = try SourceProperty(keyframes: [SourceKeyframe(startFrame: 0, endFrame: 10,
            startValue: first, endValue: last, easing: .linear, spatialCurve: nil)])
        let transform = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 7, y: 9), scale: .one, rotation: 0, opacity: 255))
        let size = try PAGSize(width: 30, height: 30)
        let layer = SceneFixtures.layer(1, start: 5, duration: 20, transform: transform,
            content: .solid(size: size, color: .defaultFill),
            masks: [MaskTestSupport.mask(path)])
        let file = try SceneFixtures.build([SceneFixtures.composition(1, layers: [layer])])
        let plan = try await prepare(file, frame: 10).plan.commands
        let begin = try #require(plan.firstIndex { if case .beginMask = $0 { true } else { false } })
        let solid = try #require(plan.firstIndex { if case .solid = $0 { true } else { false } })
        let end = try #require(plan.firstIndex { if case .endMask = $0 { true } else { false } })
        #expect(begin < solid && solid < end)
        guard case .beginMask(let mask) = plan[begin] else { return }
        #expect(mask.layerID.path == [1])
        #expect(mask.matrix.tx == 7 && mask.matrix.ty == 9)
        guard case .path(let sampledPath) = mask.source else {
            Issue.record("单路径计划必须保留原路径来源")
            return
        }
        #expect(sampledPath.points[0].x == 20)
        #expect(mask.isInverted == false)
    }

    /// 预合成蒙版须只覆盖整个子组而不泄漏给兄弟层，首Subtract只改变补集位。
    @Test func precompositionMaskWrapsSubtreeAndRestoresSibling() async throws {
        let size = try PAGSize(width: 10, height: 10)
        let child = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(11, content: .solid(size: size, color: .defaultFill)),
            SceneFixtures.layer(12, content: .solid(size: size, color: .defaultFill))
        ])
        let mask = MaskTestSupport.mask(.init(constant: try square(at: 0)), mode: .subtract)
        let root = try SceneFixtures.composition(2, layers: [
            SceneFixtures.layer(21, content: .precomposition(id: 1, startFrame: 0), masks: [mask]),
            SceneFixtures.layer(22, content: .solid(size: size, color: .defaultFill))
        ])
        let file = try SceneFixtures.build([child, root])
        let commands = try await prepare(file, frame: 0).plan.commands
        let begin = try #require(commands.firstIndex { if case .beginMask = $0 { true } else { false } })
        let end = try #require(commands.firstIndex { if case .endMask = $0 { true } else { false } })
        guard case .beginMask(let sampled) = commands[begin] else { return }
        #expect(sampled.layerID.path == [21] && sampled.isInverted)
        let childDraws = commands[begin..<end].compactMap { command -> [UInt32]? in
            if case .solid(let value) = command { value.layerID.path } else { nil }
        }
        #expect(childDraws == [[21, 12], [21, 11]])
        let outside = Array(commands[..<begin]) + Array(commands[(end + 1)...])
        let siblings = outside.compactMap { command -> [UInt32]? in
            if case .solid(let value) = command { value.layerID.path } else { nil }
        }
        #expect(siblings == [[22]])
    }

    /// 同层两条有效源路径在计划中形成一个成对作用域，并携带完整有序Boolean来源。
    @Test func multiplePathsFormOneMaskScope() async throws {
        let first = try square(at: 0)
        let second = try square(at: 5)
        let size = try PAGSize(width: 30, height: 30)
        let layer = SceneFixtures.layer(1, content: .solid(size: size, color: .defaultFill), masks: [
            MaskTestSupport.mask(.init(constant: first), mode: .add),
            MaskTestSupport.mask(.init(constant: second), mode: .difference)
        ])
        let file = try SceneFixtures.build([SceneFixtures.composition(1, layers: [layer])])
        let commands = try await prepare(file, frame: 0).plan.commands
        let masks = commands.compactMap { if case .beginMask(let value) = $0 { value } else { nil } }
        let mask = try #require(masks.first)
        #expect(masks.count == 1)
        guard case .expression(let expression) = mask.source else {
            Issue.record("同层多项必须进入有序来源")
            return
        }
        #expect(expression.terms.count == 2 && expression.terms[0].path === first)
        #expect(expression.terms[1].path === second && expression.terms[1].mode == .difference)
        #expect(mask.isInverted == false)
        #expect(commands.filter { if case .endMask = $0 { true } else { false } }.count == 1)
    }

    /// 无模糊的透明度分支保留完整列表，并准备一次整层内容与mask附件且完整归还。
    @Test func featherPlanRetainsWholeListAndPreparesLocalEffect() async throws {
        let path = try square(at: 0)
        let size = try PAGSize(width: 10, height: 10)
        let ordinary = MaskTestSupport.mask(.init(constant: path))
        let feather = MaskTestSupport.mask(.init(constant: path), feather: .init(constant: .zero))
        let resources = try MetalResources(device: #require(MTLCreateSystemDefaultDevice()))
        for masks in [[feather], [ordinary, feather]] {
            let source = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1,
                content: .solid(size: size, color: .defaultFill), masks: masks)])
            let file = try SceneFixtures.build([source])
            let frame = try await prepare(file, frame: 0)
            let scopes = frame.plan.commands.compactMap { command -> FrameMask? in
                if case .beginMask(let value) = command { value } else { nil }
            }
            let mask = try #require(scopes.first)
            #expect(scopes.count == 1)
            guard case .feather(let sampled) = mask.source else {
                Issue.record("羽化分支不得退回普通路径裁剪")
                continue
            }
            #expect(sampled.items.count == masks.count)
            #expect(frame.plan.commands.filter { if case .endMask = $0 { true } else { false } }.count == 1)
            let batch = try MetalFramePreparation.prepare(frame, width: 100, height: 100, resources: resources)
            #expect(batch.featherWorks.count == 1)
            #expect(batch.passes.last?.draws.count == 1)
            #expect(batch.passes.last?.draws.first?.featherMaskTexture != nil)
            batch.releaseTransients()
            #expect(resources.groups.activeBytes == 0)
        }
    }

    /// 大sigma必须创建局部降采样/钳后Gaussian/回放大三段工作，释放批次后附件归零。
    @Test func largeFeatherPreparesResamplingAndReleasesAttachments() async throws {
        let path = try square(at: 0)
        let size = try PAGSize(width: 10, height: 10)
        let feather = MaskTestSupport.mask(.init(constant: path),
            feather: .init(constant: ScenePoint(x: 22, y: 22)))
        let layer = SceneFixtures.layer(1, content: .solid(size: size, color: .defaultFill), masks: [feather])
        let file = try SceneFixtures.build([SceneFixtures.composition(1, layers: [layer])])
        let frame = try await prepare(file, frame: 0)
        let resources = try MetalResources(device: #require(MTLCreateSystemDefaultDevice()))
        let batch = try MetalFramePreparation.prepare(frame, width: 100, height: 100, resources: resources)
        let item = try #require(batch.featherWorks.first?.items.first)
        #expect(item.downsample != nil && item.upsample != nil)
        #expect(item.blurPasses.count == 2 && item.blurPasses.allSatisfy { $0.axis.radius == 20 })
        batch.releaseTransients()
        #expect(resources.groups.activeBytes == 0)
    }

    /// 大sigma项起点落在总体surface左侧时，源clip缩小卷积样本区且完整借用可归还。
    @Test func highSigmaNegativeItemOriginUsesClippedSample() async throws {
        let path = try SourcePath(verbs: [.move, .line, .line, .line, .close], points: [
            ScenePoint(x: -10, y: 0), ScenePoint(x: 60, y: 0),
            ScenePoint(x: 60, y: 100), ScenePoint(x: -10, y: 100)
        ])
        let size = try PAGSize(width: 100, height: 100)
        let mask = MaskTestSupport.mask(.init(constant: path),
            feather: .init(constant: ScenePoint(x: 22, y: 0)))
        let layer = SceneFixtures.layer(1, content: .solid(size: size, color: .defaultFill), masks: [mask])
        let frame = try await prepare(SceneFixtures.build([
            SceneFixtures.composition(1, layers: [layer])
        ]), frame: 0)
        let resources = try MetalResources(device: #require(MTLCreateSystemDefaultDevice()))
        let batch = try MetalFramePreparation.prepare(frame, width: 100, height: 100, resources: resources)
        let reduction = try #require(batch.featherWorks.first?.items.first?.downsample)
        #expect(reduction.destination.texture.width == 95)
        batch.releaseTransients()
        #expect(resources.groups.activeBytes == 0)
    }

    /// 原路径或矩形扩张表达式的内容附件已借出后预算失败，均须立即归还全部局部附件。
    @Test(arguments: [0.0, 4.0]) func featherFailureAfterContentLoanReleasesAttachment(
        expansion: Double) async throws {
        let path = try square(at: 0)
        let size = try PAGSize(width: 10, height: 10)
        let mask = MaskTestSupport.mask(.init(constant: path), opacity: .init(constant: 128),
                                        expansion: .init(constant: expansion))
        let layer = SceneFixtures.layer(1, content: .solid(size: size, color: .defaultFill), masks: [mask])
        let frame = try await prepare(SceneFixtures.build([
            SceneFixtures.composition(1, layers: [layer])
        ]), frame: 0)
        let commands = frame.plan.commands
        let begin = try #require(commands.firstIndex { if case .beginMask = $0 { true } else { false } })
        let end = try #require(commands.lastIndex { if case .endMask = $0 { true } else { false } })
        guard case .beginMask(let sampled) = commands[begin] else {
            Issue.record("缺少羽化效果入口")
            return
        }
        let resources = try MetalResources(device: #require(MTLCreateSystemDefaultDevice()))
        var measurement = try MetalFrameBudget()
        let effect = try #require(try FeatherMaskEffectPreparation.make(sampled,
            commands: commands[(begin + 1)..<end], frame: frame, resources: resources, budget: &measurement))
        var previewBudget = try MetalFrameBudget()
        let preview = try resources.groups.acquire(width: effect.layout.width,
            height: effect.layout.height, budget: &previewBudget)
        let firstLoanCost = preview.byteCount
        #expect(resources.groups.release(preview))
        // 预算恰好支付纯值描述与首张附件；内容批次下一次网格/命令收费必定失败。
        var limited = try MetalFrameBudget(maximumBytes: measurement.usedBytes + firstLoanCost)
        #expect(throws: PAGError.resourceLimitExceeded("maximumMetalFrameBytes")) {
            try MetalFeatherPreparation.prepare(sampled, commands: commands[(begin + 1)..<end],
                                                frame: frame, resources: resources, budget: &limited, visible: true)
        }
        #expect(resources.groups.activeBytes == 0)
    }

    /// 父预合成与子层各有蒙版时，Metal须明确拒绝嵌套且不留下局部附件。
    @Test func nestedPrecompositionMasksRejectWholeBatch() async throws {
        let size = try PAGSize(width: 10, height: 10)
        let mask = MaskTestSupport.mask(.init(constant: try square(at: 0)))
        let child = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(11,
            content: .solid(size: size, color: .defaultFill), masks: [mask])])
        let root = try SceneFixtures.composition(2, layers: [SceneFixtures.layer(21,
            content: .precomposition(id: 1, startFrame: 0), masks: [mask])])
        let file = try SceneFixtures.build([child, root])
        let frame = try await prepare(file, frame: 0)
        let resources = try MetalResources(device: #require(MTLCreateSystemDefaultDevice()))
        #expect(throws: PAGError.unsupportedFeature("nestedMaskPaths")) {
            try MetalFramePreparation.prepare(frame, width: 100, height: 100, resources: resources)
        }
        #expect(resources.groups.activeBytes == 0)
    }

    /// 创建非零面积的同拓扑测试路径；只表达语义图而不声称是PAG字节样本。
    private func square(at x: Double) throws -> SourcePath {
        try SourcePath(verbs: [.move, .line, .line, .line, .close],
                       points: [ScenePoint(x: x, y: 0), ScenePoint(x: x + 10, y: 0),
                                ScenePoint(x: x + 10, y: 10), ScenePoint(x: x, y: 10)])
    }

    /// 以30fps把源定义请求为同一显示大小；仅返回纯值帧计划。
    private func prepare(_ file: PAGFile, frame: Int64) async throws -> PreparedFrame {
        let scene = try await PreparedScene.prepare(file.composition)
        let time = try SceneValidator.time(frame: frame, rate: 30)
        return try await FramePlanner.prepare(scene, at: time, targetSize: PAGSize(width: 100, height: 100),
                                              scale: 1, mode: .stretch)
    }
}
