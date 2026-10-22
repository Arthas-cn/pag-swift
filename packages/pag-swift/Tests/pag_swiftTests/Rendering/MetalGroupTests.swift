import Metal
import Testing
@testable import pag_swift

/// 真实GPU资源下验证组计划与附件生命周期；不将计划断言冒充像素对照。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要可访问的主机 Metal 设备"), .timeLimit(.minutes(1)))
struct MetalGroupTests {
    /// 重叠子图元保留自身alpha，局部结果只统一乘一次整体alpha。
    @Test func overlappingChildrenKeepOneCompositeAlpha() async throws {
        let owner = MetalGroupTestOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifyOverlap()
    }

    /// 嵌套局部组按后序准备，祖先裁剪只在最外层结果应用。
    @Test func nestedGroupsPreserveOrderAndClipScope() async throws {
        let owner = MetalGroupTestOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifyNested()
    }

    /// 不透明、零alpha和单图元组不分配附件；完全不可见内容不上传输入。
    @Test func simpleGroupsAvoidAttachments() async throws {
        let owner = MetalGroupTestOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifySimple()
    }

    /// 无快照预合成的外层alpha逐draw消费，重叠子层不能借整体合成附件。
    @Test func uncachedCompositionInheritsAlphaPerDraw() async throws {
        let owner = MetalGroupTestOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifyUncachedComposition()
    }

    /// 静态Shape/Text虽满足Picture候选，未建立快照的生产帧仍逐draw且零外层附件。
    @Test func eligibleContentWithoutSnapshotUsesPerDraw() async throws {
        let half = SourceTransformProperties(constant: SourceTransform(anchor: .zero, position: .zero,
            scale: .one, rotation: 0, opacity: 128))
        let rectangle = SourceShape.rectangle(reversed: false, size: ScenePoint(x: 40, y: 40),
                                               position: ScenePoint(x: 40, y: 40), roundness: 0)
        let shape = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(1, transform: half,
            content: .shape([rectangle, .fill(color: SceneColor(red: 255, green: 0, blue: 0), opacity: 255),
                             .fill(color: SceneColor(red: 0, green: 0, blue: 255), opacity: 255)]))])
        var style = try TextFixtures.source().style
        style.strokeColor = try PAGColor(red: 1, green: 0, blue: 0)
        style.strokeWidth = 2
        let text = try SceneFixtures.composition(2, layers: [SceneFixtures.layer(2, transform: half,
            content: .text(try TextFixtures.source(style: style)))])
        let owner = MetalGroupTestOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        for source in [shape, text] {
            let file = try SceneFixtures.build([source])
            let scene = try await PreparedScene.prepare(file.composition)
            var budget = FramePlanBudget(limit: 1_000_000)
            let indices = [source.id: 0]
            let ranges = try VectorStaticRanges.make(compositions: [source], indices: indices, budget: &budget)
            let candidate = try PictureCandidates.make(compositions: [source], indices: indices,
                                                       vectorRanges: ranges, budget: &budget)
            #expect(candidate.layerContent == [[true]])
            let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: source.size, scale: 1, mode: .none)
            let group = try #require(frame.plan.commands.compactMap { command -> FrameOpacityGroup? in
                if case .beginOpacityGroup(let value) = command { value } else { nil }
            }.first)
            #expect(group.application == .perDraw && group.opacity == Double(128) / 255)
            try await owner.verifyUncachedEligible(frame)
        }
    }

    /// 两层旋转预合成的定义clip保留在组内，候选外层alpha逐draw消费且不创建附件。
    @Test func rotatedNestedCompositionsPreserveDirectDrawing() async throws {
        let composition = try MetalGroupFixtures.rotatedUncachedComposition()
        let scene = try await PreparedScene.prepare(composition)
        let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: composition.size,
                                                   scale: 1, mode: .none)
        let groups = frame.plan.commands.compactMap { command -> FrameGroup? in
            if case .beginGroup(let value) = command { value } else { nil }
        }
        #expect(groups.count == 3 && groups.allSatisfy { $0.application == .perDraw })
        #expect(groups.dropFirst().allSatisfy { abs($0.clip.matrix.b) > 0.1 })
        #expect(groups[1].opacity == Double(128) / 255)
        #expect(groups[2].opacity == 1)
        let alphaGroups = frame.plan.commands.compactMap { command -> FrameOpacityGroup? in
            if case .beginOpacityGroup(let value) = command { value } else { nil }
        }
        #expect(alphaGroups.count == 1)
        #expect(alphaGroups.allSatisfy { $0.opacity == Double(128) / 255 && $0.application == .perDraw })
        #expect(alphaGroups.first?.layerID == groups[2].layerID)
        try await MetalGroupTestOwner(device: try #require(MTLCreateSystemDefaultDevice())).verifyRotatedUncached(frame)
    }

    /// 已经生成附件后遇到非法计划，准备整体失败并归还全部活动借用。
    @Test func failedPreparationReturnsBorrowedAttachments() async throws {
        let owner = MetalGroupTestOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifyFailure()
    }

    /// 纹理只有归还后才复用；借用身份更新，旧归还不会释放当前工作。
    @Test func poolEnforcesBudgetsAndLoanIdentity() async throws {
        let owner = MetalGroupTestOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifyPool()
    }
}

/// 每个测试独占GPU域，裸纹理只在该actor中比较。
private actor MetalGroupTestOwner {
    /// sending入口转交的唯一设备别名。
    private let device: any MTLDevice

    /// 接收真实设备，测试调用域此后不能再使用它。
    init(device: sending any MTLDevice) { self.device = device }

    /// 两个相交矩形的局部附件严格小于显示目标，源alpha不被组alpha污染。
    func verifyOverlap() throws {
        let resources = try MetalResources(device: device)
        let commands = try MetalGroupFixtures.group(0.5, [MetalGroupFixtures.solid(), MetalGroupFixtures.solid(x: 20, alpha: 0.75)])
        let batch = try Self.prepare(commands, resources)
        defer { batch.releaseTransients() }
        #expect(batch.passes.count == 2 && batch.loans.count == 1)
        let content = batch.passes[0], root = batch.passes[1]
        #expect(content.rect == RenderPixelRect(x: 9, y: 19, width: 32, height: 22))
        #expect(content.draws.map(\.uniforms.color.w) == [1, 0.75])
        #expect(content.draws.allSatisfy { $0.uniforms.targetOffset == SIMD4<Float>(9, 19, 0, 0) })
        #expect(root.attachment == nil && root.draws.count == 1 && root.draws[0].uniforms.color == SIMD4<Float>(repeating: 0.5))
        #expect(root.draws[0].texture === content.attachment?.texture)
        #expect(content.attachment?.texture.storageMode == .private)
        #expect(content.attachment?.texture.usage == [.renderTarget, .shaderRead])
    }

    /// 子结果先进入父局部pass，祖先真实旋转裁剪不提前乘入子内容。
    func verifyNested() throws {
        let resources = try MetalResources(device: device)
        let clip = FrameClip(size: try PAGSize(width: 80, height: 80), matrix: try .rotation(degrees: 10))
        let inner = try MetalGroupFixtures.group(0.5, [MetalGroupFixtures.solid(), MetalGroupFixtures.solid(x: 20)])
        let outer = try MetalGroupFixtures.group(0.25, inner + [MetalGroupFixtures.solid(x: 30)])
        let commands = [FrameCommand.beginGroup(FrameGroup(layerID: nil, frame: 0, clip: clip, opacity: 1))]
            + outer + [.endGroup] + [try MetalGroupFixtures.solid(x: 90)]
        let batch = try Self.prepare(commands, resources)
        defer { batch.releaseTransients() }
        #expect(batch.passes.count == 3 && batch.loans.count == 2)
        #expect(batch.passes[0].draws.count == 2 && batch.passes[1].draws.count == 2)
        #expect(batch.passes[1].draws[0].texture === batch.passes[0].attachment?.texture)
        #expect(batch.passes[0].draws.allSatisfy { $0.clips.count == 0 })
        #expect(batch.passes[1].draws.allSatisfy { $0.clips.count == 0 })
        let root = batch.passes[2]
        #expect(root.draws.count == 2 && root.draws[0].clips.count == 1 && root.draws[1].clips.count == 0)
        #expect(root.draws[0].uniforms.color.w == 0.25 && batch.passes[1].draws[0].uniforms.color.w == 0.5)
        var expected = MetalClipValues()
        try expected.append(clip)
        #expect(root.draws[0].clips.sources == expected.sources)
    }

    /// 优化只发生在等价语义下，零alpha仍要求组命令配对。
    func verifySimple() throws {
        let resources = try MetalResources(device: device)
        let hidden = try Self.prepare(MetalGroupFixtures.group(0, [MetalGroupFixtures.solid(), MetalGroupFixtures.solid(x: 20)]), resources)
        defer { hidden.releaseTransients() }
        #expect(hidden.loans.isEmpty && hidden.drawCount == 0 && resources.count == 0)
        let opaque = try Self.prepare(MetalGroupFixtures.group(1, [MetalGroupFixtures.solid(), MetalGroupFixtures.solid(x: 20)]), resources)
        defer { opaque.releaseTransients() }
        #expect(opaque.passes.count == 1 && opaque.drawCount == 2 && opaque.loans.isEmpty)
        let folded = try Self.prepare(MetalGroupFixtures.group(0.5, MetalGroupFixtures.group(0.25, [MetalGroupFixtures.solid(alpha: 0.5)])), resources)
        defer { folded.releaseTransients() }
        #expect(folded.loans.isEmpty && folded.drawCount == 1 && folded.passes[0].draws[0].uniforms.color.w == 0.0625)
        let invisible = try Self.prepare(MetalGroupFixtures.group(0.5, [MetalGroupFixtures.solid(x: 200), MetalGroupFixtures.solid(x: 210)]), resources)
        defer { invisible.releaseTransients() }
        #expect(invisible.loans.isEmpty && invisible.drawCount == 0)
    }

    /// 根矩形裁剪随两次实际绘制继承，均乘半透明且没有中间附件。
    func verifyUncachedComposition() throws {
        let resources = try MetalResources(device: device)
        let clip = FrameClip(size: try PAGSize(width: 80, height: 80), matrix: .identity)
        let commands: [FrameCommand] = [
            .beginGroup(FrameGroup(layerID: nil, frame: 0, clip: clip, opacity: 0.5, application: .perDraw)),
            try MetalGroupFixtures.solid(), try MetalGroupFixtures.solid(x: 20), .endGroup
        ]
        let batch = try Self.prepare(commands, resources)
        defer { batch.releaseTransients() }
        #expect(batch.passes.count == 1 && batch.loans.isEmpty)
        let draws = try #require(batch.passes.last).draws
        #expect(draws.count == 2)
        #expect(draws.allSatisfy { $0.uniforms.color.w == 0.5 && $0.clips.count == 1 })
    }

    /// 实际源计划不因候选true就生成临时组合纹理；多paint或glyph仍各自消耗外层alpha。
    func verifyUncachedEligible(_ frame: PreparedFrame) throws {
        let resources = try MetalResources(device: device)
        let batch = try MetalFramePreparation.prepare(frame, width: 100, height: 100, resources: resources)
        defer { batch.releaseTransients() }
        #expect(batch.passes.count == 1 && batch.loans.isEmpty && resources.groups.activeBytes == 0)
        let draws = try #require(batch.passes.last).draws
        #expect(draws.count > 1)
        #expect(draws.allSatisfy { abs($0.uniforms.color.w - Float(128.0 / 255)) < 0.0001 })
    }

    /// 旋转后的三个真实clip同时附着于两个叶draw，继承alpha的乘积不生成局部纹理。
    func verifyRotatedUncached(_ frame: PreparedFrame) throws {
        let resources = try MetalResources(device: device)
        let batch = try MetalFramePreparation.prepare(frame, width: 100, height: 100, resources: resources)
        defer { batch.releaseTransients() }
        #expect(batch.passes.count == 1 && batch.loans.isEmpty)
        let draws = try #require(batch.passes.last).draws
        let alpha = Float(128.0 / 255) * Float(128.0 / 255)
        #expect(draws.count == 2)
        #expect(draws.allSatisfy { $0.clips.count == 3 && abs($0.uniforms.color.w - alpha) < 0.0001 })
    }

    /// 关闭多图元组后才出现错误，确保覆盖已经借出纹理的失败清理路径。
    func verifyFailure() throws {
        let resources = try MetalResources(device: device)
        let group = try MetalGroupFixtures.group(0.5, [MetalGroupFixtures.solid(), MetalGroupFixtures.solid(x: 20)])
        #expect(throws: PAGError.renderingFailure("metalUnbalancedGroups")) { try Self.prepare(group + [.endGroup], resources) }
        #expect(resources.groups.activeBytes == 0 && resources.groups.freeBytes > 0)
        let valid = try Self.prepare(group, resources)
        #expect(resources.groups.activeBytes > 0)
        valid.releaseTransients()
        #expect(resources.groups.activeBytes == 0)
        let next = try Self.prepare(group, resources)
        defer { next.releaseTransients() }
        valid.releaseTransients()
        #expect(resources.groups.contains(next.loans[0]) && !resources.groups.contains(valid.loans[0]))
        #expect(throws: PAGError.renderingFailure("metalGroupOpacity")) {
            try Self.prepare(MetalGroupFixtures.group(.nan, []), resources)
        }
    }

    /// 活动与空闲字节分别受限，禁用空闲缓存不破坏活动借用的生命周期。
    func verifyPool() throws {
        var budget = try MetalFrameBudget()
        let probe = try MetalGroupPool(device: device, freeLimit: 0)
        let measured = try probe.acquire(width: 10, height: 10, budget: &budget)
        let cost = measured.byteCount
        #expect(cost >= measured.texture.allocatedSize + 512 && cost >= 10 * 10 * 4 + 512)
        probe.release(measured)
        let pool = try MetalGroupPool(device: device, freeLimit: cost, activeLimit: cost * 2)
        let a = try pool.acquire(width: 10, height: 10, budget: &budget)
        let b = try pool.acquire(width: 10, height: 10, budget: &budget)
        #expect(a.texture !== b.texture && pool.activeBytes == cost * 2)
        #expect(throws: PAGError.resourceLimitExceeded("maximumActiveMetalGroupBytes")) {
            try pool.acquire(width: 10, height: 10, budget: &budget)
        }
        #expect(pool.release(a))
        let c = try pool.acquire(width: 10, height: 10, budget: &budget)
        #expect(c.texture === a.texture && c.id != a.id)
        #expect(!pool.release(a) && pool.contains(c))
        pool.release(b)
        pool.release(c)
        #expect(pool.activeBytes == 0 && pool.freeBytes == cost)
        let latest = try pool.acquire(width: 10, height: 10, budget: &budget)
        #expect(latest.texture === c.texture && latest.texture !== b.texture)
        pool.release(latest)
        var tiny = try MetalFrameBudget(maximumBytes: cost - 1)
        #expect(throws: PAGError.resourceLimitExceeded("maximumMetalFrameBytes")) {
            try pool.acquire(width: 10, height: 10, budget: &tiny)
        }
        #expect(pool.activeBytes == 0 && pool.freeBytes == cost)
        if cost > 10 * 10 * 4 + 512 {
            // 当前GPU确有额外分配开销时，验证创建后发现超预算不会发布借用。
            let tooSmall = try MetalGroupPool(device: device, activeLimit: cost - 1)
            #expect(throws: PAGError.resourceLimitExceeded("maximumActiveMetalGroupBytes")) {
                try tooSmall.acquire(width: 10, height: 10, budget: &budget)
            }
            #expect(tooSmall.activeBytes == 0 && tooSmall.freeBytes == 0)
        }
        let disabled = try MetalGroupPool(device: device, freeLimit: 0)
        let uncached = try disabled.acquire(width: 10, height: 10, budget: &budget)
        disabled.release(uncached)
        #expect(disabled.freeBytes == 0 && disabled.activeBytes == 0)
    }

    /// 使用真实资源构建100×100帧，调用方负责结束所有成功返回的借用。
    private nonisolated static func prepare(_ commands: [FrameCommand], _ resources: MetalResources) throws -> MetalFrameBatch {
        try MetalFramePreparation.prepare(MetalGroupFixtures.frame(commands), width: 100, height: 100, resources: resources)
    }
}
