import Metal
import Testing
@testable import pag_swift

/// 普通Shape组的逐draw继承alpha及与现有composite边界的交互，不用附件数量代替像素回归。
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要Metal设备"))
struct MetalInheritedOpacityTests {
    /// 嵌套继承逐级乘一次、退出恢复父值，真实裁剪始终保留且不产生局部附件。
    @Test func nestedInheritanceKeepsClipsAndSiblingState() async throws {
        let owner = InheritedOpacityOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifyNested()
    }

    /// 继承包composite只乘其结果，composite包继承则先乘子draw，再组合外层结果。
    @Test func compositeBoundariesKeepTheirOwnConsumptionPoint() async throws {
        let owner = InheritedOpacityOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifyCompositeInteraction()
    }

    /// 零/一alpha、非法值、不配对计划和预算不足保持原错误语义，失败不泄漏已有附件。
    @Test func emptyInvalidAndBudgetedScopesFailAtomically() async throws {
        let owner = InheritedOpacityOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifyBoundaries()
    }

    /// 相同已借composite输入只差一次继承乘色，新增32字节收费不能被缓存命中或失败回收绕过。
    @Test func inheritedColorChargeHasExactBudgetBoundary() async throws {
        let owner = InheritedOpacityOwner(device: try #require(MTLCreateSystemDefaultDevice()))
        try await owner.verifyColorBudget()
    }

    /// 真实Shape准备输出将内部组明确标为perDraw，不依赖手写FramePlan才触发新分支。
    @Test func shapePlannerMarksInternalGroups() async throws {
        let scene = try await MetalStrokeFixtures.scene(MetalShapePropertyFixtures.groupOpacity())
        let frame = try await ShapePathFixtures.plan(scene, at: 5)
        let groups = frame.plan.commands.compactMap { command -> FrameOpacityGroup? in
            if case .beginOpacityGroup(let group) = command { return group }
            return nil
        }
        #expect(groups.count == 1 && groups[0].application == .perDraw)
        #expect(abs(groups[0].opacity - 127.0 / 255) < 1e-6)
    }
}

/// 每个测试独占的GPU域，输入为纯值命令，裸设备和批次不跨actor返回。
private actor InheritedOpacityOwner {
    /// 调用方通过sending转交的设备，仅由本actor使用。
    let device: any MTLDevice

    /// 接收设备所有权，避免测试并发共享可变渲染资源。
    init(device: sending any MTLDevice) { self.device = device }

    /// 两级继承与作用域外图元按独立乘积断言，祖先旋转裁剪不能转移到不存在的附件。
    func verifyNested() throws {
        let resources = try MetalResources(device: device)
        let inner = try Self.inherited(0.5, [MetalGroupFixtures.solid(), MetalGroupFixtures.solid(alpha: 0.75)])
        let outer = try Self.inherited(0.25, inner + [MetalGroupFixtures.solid()])
        let clip = FrameClip(size: try PAGSize(width: 80, height: 80), matrix: try .rotation(degrees: 10))
        let commands: [FrameCommand] = [.beginGroup(.init(layerID: nil, frame: 0, clip: clip, opacity: 1))]
            + outer + [.endGroup, try MetalGroupFixtures.solid()]
        let batch = try Self.prepare(commands, resources)
        defer { batch.releaseTransients() }
        #expect(batch.passes.count == 1 && batch.loans.isEmpty)
        #expect(batch.passes[0].draws.map(\.uniforms.color.w) == [0.125, 0.09375, 0.25, 1])
        #expect(batch.passes[0].draws.map(\.clips.count) == [1, 1, 1, 0])
    }

    /// 不同边界嵌套时，已编码子pass保持自己的alpha，外继承只改变剩下的结果图元。
    func verifyCompositeInteraction() throws {
        let resources = try MetalResources(device: device)
        let children = try [MetalGroupFixtures.solid(), MetalGroupFixtures.solid(x: 20, alpha: 0.75)]
        let first = try Self.prepare(Self.inherited(0.25, MetalGroupFixtures.group(0.5, children)), resources)
        defer { first.releaseTransients() }
        #expect(first.passes.count == 2 && first.loans.count == 1)
        #expect(first.passes[0].draws.map(\.uniforms.color.w) == [1, 0.75])
        #expect(first.passes[1].draws.map(\.uniforms.color.w) == [0.125])
        let second = try Self.prepare(MetalGroupFixtures.group(0.5, Self.inherited(0.25, children)), resources)
        defer { second.releaseTransients() }
        #expect(second.passes.count == 2 && second.loans.count == 1)
        #expect(second.passes[0].draws.map(\.uniforms.color.w) == [0.25, 0.1875])
        #expect(second.passes[1].draws.map(\.uniforms.color.w) == [0.5])
    }

    /// 预算和命令错误沿整帧失败回收；普通继承零值不上传子内容。
    func verifyBoundaries() throws {
        let resources = try MetalResources(device: device)
        let children = try [MetalGroupFixtures.solid(), MetalGroupFixtures.solid(x: 20)]
        for alpha in [0.0, 1.0] {
            let batch = try Self.prepare(Self.inherited(alpha, children), resources)
            defer { batch.releaseTransients() }
            #expect(batch.loans.isEmpty && batch.drawCount == (alpha == 0 ? 0 : 2))
        }
        for alpha in [-1.0, 2, .nan, .infinity] {
            #expect(throws: PAGError.renderingFailure("metalGroupOpacity")) {
                try Self.prepare(Self.inherited(alpha, children), resources)
            }
        }
        let commands = try Self.inherited(0.5, MetalGroupFixtures.group(0.5, children))
        #expect(throws: PAGError.renderingFailure("metalUnbalancedGroups")) {
            try Self.prepare(commands + [.endOpacityGroup], resources)
        }
        #expect(resources.groups.activeBytes == 0)
        #expect(throws: PAGError.resourceLimitExceeded("maximumMetalFrameBytes")) {
            try MetalFramePreparation.prepare(MetalGroupFixtures.frame(commands), width: 100, height: 100,
                resources: resources, maximumBytes: 512)
        }
        #expect(resources.groups.activeBytes == 0)
    }

    /// 用同一暖资源找到无额外乘色的最小预算，再对只差一次乘色的计划作32字节临界对照。
    func verifyColorBudget() throws {
        let resources = try MetalResources(device: device)
        let children = try MetalGroupFixtures.group(0.5, [MetalGroupFixtures.solid(), MetalGroupFixtures.solid(x: 20)])
        let plain = try Self.inherited(1, children)
        let multiplied = try Self.inherited(0.5, children)
        let warm = try Self.prepare(plain, resources)
        try #require(warm.loans.count == 1)
        warm.releaseTransients()
        var lower = 1, upper = 1_048_576
        // 固定暖输入和附件尺寸，每次试验都归还loan，二分不依赖生产计费公式构造基准值。
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            do {
                let batch = try MetalFramePreparation.prepare(MetalGroupFixtures.frame(plain), width: 100, height: 100,
                    resources: resources, maximumBytes: middle)
                batch.releaseTransients()
                upper = middle
            } catch PAGError.resourceLimitExceeded("maximumMetalFrameBytes") {
                lower = middle + 1
            }
            #expect(resources.groups.activeBytes == 0)
        }
        let base = try MetalFramePreparation.prepare(MetalGroupFixtures.frame(plain), width: 100, height: 100,
            resources: resources, maximumBytes: lower)
        base.releaseTransients()
        for extra in [0, 31] {
            #expect(throws: PAGError.resourceLimitExceeded("maximumMetalFrameBytes")) {
                try MetalFramePreparation.prepare(MetalGroupFixtures.frame(multiplied), width: 100, height: 100,
                    resources: resources, maximumBytes: lower + extra)
            }
            #expect(resources.groups.activeBytes == 0)
        }
        let exact = try MetalFramePreparation.prepare(MetalGroupFixtures.frame(multiplied), width: 100, height: 100,
            resources: resources, maximumBytes: lower + 32)
        #expect(exact.loans.count == 1 && exact.passes.last?.draws.first?.uniforms.color.w == 0.25)
        exact.releaseTransients()
        #expect(resources.groups.activeBytes == 0)
    }

    /// 将纯语义命令包进现有100像素测试目标，不取得drawable或读回像素。
    private static func prepare(_ commands: [FrameCommand], _ resources: MetalResources) throws -> MetalFrameBatch {
        try MetalFramePreparation.prepare(MetalGroupFixtures.frame(commands), width: 100, height: 100, resources: resources)
    }

    /// 显式选择perDraw；与旧fixture的composite对照，避免两个测试都走同一默认值。
    private static func inherited(_ alpha: Double, _ children: [FrameCommand]) throws -> [FrameCommand] {
        [.beginOpacityGroup(.init(layerID: try MetalGroupFixtures.layer, opacity: alpha, application: .perDraw))]
            + children + [.endOpacityGroup]
    }
}
