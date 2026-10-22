import Metal
import Testing
@testable import pag_swift

/// 羽化内容测量应在所属图层坐标里保留完整源范围和预合成裁剪，不借显示目标裁掉卷积输入。
struct FeatherMaskContentBoundsTests {
    /// 图层跨出根合成右边界时，测量仍保留本层完整20点内容供后续局部效果取样。
    @Test func keepsLayerContentOutsideAncestorClip() async throws {
        let size = try PAGSize(width: 20, height: 10)
        let transform = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 90, y: 12), scale: .one, rotation: 0, opacity: 255))
        let layer = SceneFixtures.layer(1, transform: transform,
            content: .solid(size: size, color: .defaultFill), masks: [try featherMask()])
        let frame = try await prepare([SceneFixtures.composition(1, layers: [layer])])
        let measured = try measure(frame)
        #expect(measured == (try RenderBounds(left: 0, top: 0, right: 20, bottom: 10)))
    }

    /// 子合成自身100点逻辑边界裁掉越出的后半矩形，但另一子层仍参与内容并集。
    @Test func precompositionUsesOwnClipAndAllChildren() async throws {
        let size = try PAGSize(width: 20, height: 10)
        let shifted = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 90, y: 0), scale: .one, rotation: 0, opacity: 255))
        let child = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(11, content: .solid(size: size, color: .defaultFill)),
            SceneFixtures.layer(12, transform: shifted, content: .solid(size: size, color: .defaultFill))
        ])
        let parent = SceneFixtures.layer(21, content: .precomposition(id: 1, startFrame: 0),
                                         masks: [try featherMask()])
        let frame = try await prepare([child, SceneFixtures.composition(2, layers: [parent])])
        let measured = try measure(frame)
        #expect(measured == (try RenderBounds(left: 0, top: 0, right: 100, bottom: 10)))
    }

    /// 子层40点内容先被起点(10,10)的普通矩形裁成20点，再交给父层羽化测量。
    @Test func nestedRectangleClipShrinksParentContentBounds() async throws {
        let size = try PAGSize(width: 40, height: 40)
        let path = try ShapePathFixtures.square(20)
        let child = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(11,
            content: .solid(size: size, color: .defaultFill),
            masks: [MaskTestSupport.mask(.init(constant: path))])])
        let parent = SceneFixtures.layer(21, content: .precomposition(id: 1, startFrame: 0),
                                         masks: [try featherMask()])
        let frame = try await prepare([child, SceneFixtures.composition(2, layers: [parent])])
        let actual = try measure(frame)
        let expected = try RenderBounds(left: 10, top: 10, right: 30, bottom: 30)
        #expect(actual == expected)
    }

    /// 子蒙版不是严格闭合四角矩形时须明确失败，不能用包围盒代替真实PathOp。
    @Test func nestedTriangleStillRejectsBeforeSurfaceAllocation() async throws {
        let size = try PAGSize(width: 20, height: 10)
        let triangle = try SourcePath(verbs: [.move, .line, .line, .close], points: [
            ScenePoint(x: 0, y: 0), ScenePoint(x: 20, y: 0), ScenePoint(x: 10, y: 10)
        ])
        let child = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(11,
            content: .solid(size: size, color: .defaultFill),
            masks: [MaskTestSupport.mask(.init(constant: triangle))])])
        let parent = SceneFixtures.layer(21, content: .precomposition(id: 1, startFrame: 0),
                                         masks: [try featherMask()])
        let frame = try await prepare([child, SceneFixtures.composition(2, layers: [parent])])
        #expect(throws: PAGError.unsupportedFeature("nestedMaskPaths")) { try descriptor(frame) }
    }

    /// 子矩形蒙版内容附件借出后预算失败，全部局部纹理仍由同次准备归还。
    @Test func nestedRectangleBudgetFailureReleasesContentAttachment() async throws {
        let size = try PAGSize(width: 40, height: 40)
        let child = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(11,
            content: .solid(size: size, color: .defaultFill),
            masks: [MaskTestSupport.mask(.init(constant: try ShapePathFixtures.square(20)))])])
        let parent = SceneFixtures.layer(21, content: .precomposition(id: 1, startFrame: 0),
                                         masks: [try featherMask()])
        let frame = try await prepare([child, SceneFixtures.composition(2, layers: [parent])])
        let (mask, commands) = try maskRange(frame)
        let resources = try MetalResources(device: #require(MTLCreateSystemDefaultDevice()))
        var measurement = try MetalFrameBudget()
        let effect = try #require(try FeatherMaskEffectPreparation.make(mask, commands: commands,
            frame: frame, resources: resources, budget: &measurement))
        var previewBudget = try MetalFrameBudget()
        let preview = try resources.groups.acquire(width: effect.layout.width,
            height: effect.layout.height, budget: &previewBudget)
        let firstLoanCost = preview.byteCount
        #expect(resources.groups.release(preview))
        // 恰好够描述和第一张内容附件；后续子mask网格收费失败必须回收已借附件。
        var limited = try MetalFrameBudget(maximumBytes: measurement.usedBytes + firstLoanCost)
        #expect(throws: PAGError.resourceLimitExceeded("maximumMetalFrameBytes")) {
            try MetalFeatherPreparation.prepare(mask, commands: commands,
                frame: frame, resources: resources, budget: &limited, visible: true)
        }
        #expect(resources.groups.activeBytes == 0)
    }

    /// 实际计划应形成独立内容/单项mask局部坐标，再把内容纹理映回原显示位置。
    @Test func effectDescriptorKeepsContentAndMaskCoordinateChains() async throws {
        let size = try PAGSize(width: 20, height: 10)
        let transform = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: ScenePoint(x: 90, y: 12), scale: .one, rotation: 0, opacity: 255))
        let layer = SceneFixtures.layer(1, transform: transform,
            content: .solid(size: size, color: .defaultFill), masks: [try featherMask()])
        let frame = try await prepare([SceneFixtures.composition(1, layers: [layer])])
        let effect = try #require(try descriptor(frame))
        #expect(effect.layout.width == 20 && effect.layout.height == 10)
        // 夹具方形起点为(10,10)，上游总体范围只累计右/下到110，再各外扩11。
        #expect(effect.overallWidth == 132 && effect.overallHeight == 132)
        #expect(effect.items.count == 1 && effect.items[0].width == 100)
        let item = try #require(effect.items.first)
        #expect(item.frame.plan.commands.count == 3)
        guard case .solid(let alpha) = item.frame.plan.commands[1] else {
            Issue.record("单项alpha缺少独立颜色绘制")
            return
        }
        #expect(abs(alpha.opacity - 200.0 / 255.0) < 0.000_000_1)
        let origin = try effect.contentToDisplay.applying(to: .zero)
        let far = try effect.contentToDisplay.applying(to: ScenePoint(x: 1, y: 1))
        #expect(origin == ScenePoint(x: 90, y: 12))
        #expect(far == ScenePoint(x: 110, y: 22))
        #expect(effect.overallToLocal == effect.layout.contentMatrix)
    }

    /// 非整数父缩放先量化局部表面，绘回矩阵仍须保持原本20点内容的显示尺寸。
    @Test func quantizedSurfaceReturnsToOriginalDisplayScale() async throws {
        let size = try PAGSize(width: 20, height: 10)
        let transform = SourceTransformProperties(constant: SourceTransform(anchor: .zero,
            position: .zero, scale: ScenePoint(x: 1.17, y: 1.17), rotation: 0, opacity: 255))
        let layer = SceneFixtures.layer(1, transform: transform,
            content: .solid(size: size, color: .defaultFill), masks: [try featherMask()])
        let frame = try await prepare([SceneFixtures.composition(1, layers: [layer])])
        let effect = try #require(try descriptor(frame))
        #expect(effect.layout.scale == Float(1.2))
        #expect(effect.layout.width == 24 && effect.layout.height == 12)
        let far = try effect.contentToDisplay.applying(to: ScenePoint(x: 1, y: 1))
        #expect(abs(far.x - 23.4) < 0.000_01 && abs(far.y - 11.7) < 0.000_01)
    }

    /// 描述阶段即按同一帧预算失败，不会在资源不足后借出半个局部附件。
    @Test func insufficientBudgetDoesNotBorrowAttachment() async throws {
        let size = try PAGSize(width: 20, height: 10)
        let layer = SceneFixtures.layer(1, content: .solid(size: size, color: .defaultFill),
                                         masks: [try featherMask()])
        let frame = try await prepare([SceneFixtures.composition(1, layers: [layer])])
        let (mask, commands) = try maskRange(frame)
        let resources = try MetalResources(device: #require(MTLCreateSystemDefaultDevice()))
        var budget = try MetalFrameBudget(maximumBytes: 128)
        #expect(throws: PAGError.resourceLimitExceeded("maximumMetalFrameBytes")) {
            try FeatherMaskEffectPreparation.make(mask, commands: commands, frame: frame,
                                                  resources: resources, budget: &budget)
        }
        #expect(resources.groups.activeBytes == 0)
    }

    /// 构造触发羽化整层分流的真实语义蒙版，不伪造PAG字节布局。
    private func featherMask() throws -> SourceMask {
        MaskTestSupport.mask(.init(constant: try ShapePathFixtures.square(100)),
                             opacity: .init(constant: 200))
    }

    /// 使用公共场景求值链得到成对的生产帧计划，几何测量只在Metal准备层进行。
    private func prepare(_ sources: [SourceComposition]) async throws -> PreparedFrame {
        let file = try SceneFixtures.build(sources)
        let scene = try await PreparedScene.prepare(file.composition)
        let time = try SceneValidator.time(frame: 0, rate: 30)
        return try await FramePlanner.prepare(scene, at: time,
            targetSize: PAGSize(width: 100, height: 100), scale: 1, mode: .stretch)
    }

    /// 提取第一层羽化作用域并要求其恰好配对；输出源局部边界或传播真实错误。
    private func measure(_ frame: PreparedFrame) throws -> RenderBounds? {
        let (mask, commands) = try maskRange(frame)
        let resources = try MetalResources(device: #require(MTLCreateSystemDefaultDevice()))
        var budget = try MetalFrameBudget()
        return try FeatherMaskContentBounds.measure(commands, frame: frame,
                                                     layerMatrix: mask.matrix, resources: resources, budget: &budget)
    }

    /// 从生产帧范围建立效果局部计划，不借用GPU附件或替代实际drawable验收。
    private func descriptor(_ frame: PreparedFrame) throws -> FeatherMaskEffectDescriptor? {
        let (mask, commands) = try maskRange(frame)
        let resources = try MetalResources(device: #require(MTLCreateSystemDefaultDevice()))
        var budget = try MetalFrameBudget()
        let result = try FeatherMaskEffectPreparation.make(mask, commands: commands,
            frame: frame, resources: resources, budget: &budget)
        #expect(resources.groups.activeBytes == 0)
        return result
    }

    /// 只取当前测试唯一的外层羽化命令区间，子层蒙版仍保留供测量及局部化。
    private func maskRange(_ frame: PreparedFrame) throws -> (FrameMask, ArraySlice<FrameCommand>) {
        let commands = frame.plan.commands
        let begin = try #require(commands.firstIndex { if case .beginMask = $0 { true } else { false } })
        let end = try #require(commands[(begin + 1)...].lastIndex { if case .endMask = $0 { true } else { false } })
        guard case .beginMask(let mask) = commands[begin] else {
            throw PAGError.renderingFailure("featherTestMaskScope")
        }
        return (mask, commands[(begin + 1)..<end])
    }
}
