import Testing
@testable import pag_swift

/// 首批真实图片场景的逐帧计划，以及语义图的顺序、裁剪、透明度和失败边界。
struct FramePlannerTests {
    /// replacement 的动画矩阵真正进入计划，图像摘要可解析到同一不可变源输入。
    @Test func realAnimationProducesImagePlans() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "replacement.pag"))
        let first = try await prepare(file.composition, frame: 0)
        let peak = try await prepare(file.composition, frame: 30)
        let initialImage = try #require(images(first).first)
        let peakImage = try #require(images(peak).first)
        #expect(first.plan.commands.count == 3 && peak.plan.commands.count == 3)
        #expect(first.images.count == 1 && peak.images.count == 1)
        #expect(initialImage.matrix.a == 0.25 && initialImage.matrix.tx == 336)
        #expect(abs(peakImage.matrix.a - 1) < 1e-6 && abs(peakImage.matrix.tx - 144) < 1e-6)
        #expect(initialImage.clip == nil && initialImage.opacity == 1)
        let center = try peakImage.matrix.applying(to: ScenePoint(x: 256, y: 256))
        #expect(abs(center.x - 400) < 1e-6 && abs(center.y - 400) < 1e-6)
        let input = try #require(peak.images[peakImage.resourceID])
        #expect(input.storage === first.images[initialImage.resourceID]?.storage)
        #expect(peak.plan.time.frame == 30 && peakImage.contentTime.microseconds > 0)
    }

    /// srgb 的空间路径与透明度形成真实显示命令，祖先/显示映射没有重复应用。
    @Test func realSpatialAnimationReachesPlan() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "srgb.pag"))
        let prepared = try await prepare(file.composition, frame: 43)
        let image = try #require(images(prepared).first { $0.layerID?.path == [610] })
        let anchor = try image.matrix.applying(to: ScenePoint(x: 18, y: 18))
        #expect(abs(anchor.x - 323.5420100) < 0.06 && abs(anchor.y - 1001.5686964) < 0.06)
        #expect(image.opacity > 0 && image.opacity < 1)
        #expect(prepared.images[image.resourceID] != nil)
    }

    /// 原图 scale/裁边和替换 LetterBox 各自生效；恢复原图不会沿用替换矩形或历史缓存。
    @Test func originalAndReplacementUseDifferentPlacement() async throws {
        let input = try await PAGImage.load(data: PAGFixtures.data(named: "media/rgba-corners.png"))
        let size = try PAGSize(width: 100, height: 80)
        let image = SourceImage(id: 1, image: input, logicalSize: size, scaleFactor: 0.5, anchor: ScenePoint(x: -8, y: 4))
        let source = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(10, content: .image(1))])
        let file = try SceneFixtures.build([source], resources: SourceResources(images: [1: image]))
        let original = try await prepare(file.composition)
        let sourceCommand = try #require(images(original).first)
        #expect(sourceCommand.matrix.a == 2 && sourceCommand.matrix.tx == 8 && sourceCommand.matrix.ty == -4)
        #expect(sourceCommand.clip == nil)
        var edited = file.composition
        try edited.replaceImage(input, at: 0)
        let replacement = try await prepare(edited)
        let command = try #require(images(replacement).first)
        #expect(command.matrix.a == 40 && command.matrix.d == 40 && command.matrix.tx == 10 && command.matrix.ty == 0)
        #expect(command.clip == FrameClip(size: size, matrix: .identity))
        // 相同像素摘要不意味着相同布局；替换与原图虽然共享输入，命令仍各自正确。
        #expect(command.resourceID == sourceCommand.resourceID)
        #expect(sourceCommand.matrix.a == 2)
        try edited.replaceImage(nil, at: 0)
        let restored = try await prepare(edited)
        #expect(images(restored).first?.matrix == sourceCommand.matrix)
        #expect(images(restored).first?.clip == nil)
    }

    /// 两个引用同一子合成的实例保持各自分组和时刻；逆编码顺序绘制且 alpha 不逐子层预乘。
    @Test func repeatedPrecompositionKeepsGroupBoundaries() async throws {
        let size = try PAGSize(width: 10, height: 20)
        let child = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(11, name: "first", content: .solid(size: size, color: .defaultFill)),
            SceneFixtures.layer(12, name: "second", content: .solid(size: size, color: .defaultFill))
        ])
        let half = SourceTransformProperties(constant: SourceTransform(anchor: .zero, position: ScenePoint(x: 5, y: 7),
                                                                        scale: .one, rotation: 0, opacity: 128))
        let root = try SceneFixtures.composition(2, layers: [
            SceneFixtures.layer(21, transform: half, content: .precomposition(id: 1, startFrame: 2)),
            SceneFixtures.layer(22, content: .precomposition(id: 1, startFrame: 0))
        ])
        let file = try SceneFixtures.build([child, root])
        let prepared = try await prepare(file.composition, frame: 5)
        let solids = solids(prepared)
        #expect(solids.map(\.layerID.path) == [[22, 12], [22, 11], [21, 12], [21, 11]])
        #expect(solids.allSatisfy { $0.opacity == 1 })
        #expect(solids[2].matrix.tx == 5 && solids[2].matrix.ty == 7)
        let groups = groups(prepared)
        #expect(groups.map(\.frame) == [5, 5, 3])
        #expect(groups[2].opacity == Double(128) / 255)
        #expect(groups[2].clip.matrix == solids[2].matrix)
        var depth = 0
        for command in prepared.plan.commands {
            if case .beginGroup = command { depth += 1 }
            if case .endGroup = command { depth -= 1 }
            #expect(depth >= 0)
        }
        #expect(depth == 0 && prepared.plan.commands.count == 10)
    }

    /// 根显示缩放只应用一次，旋转预合成的裁剪保持局部矩形与真实旋转矩阵。
    @Test func displayScaleAndRotatedClipRemainSeparate() async throws {
        let child = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(1, content: .solid(size: PAGSize(width: 10, height: 10), color: .defaultFill))
        ])
        let rotation = SourceTransformProperties(constant: SourceTransform(anchor: .zero, position: .zero,
                                                                           scale: .one, rotation: 90, opacity: 255))
        let root = try SceneFixtures.composition(2, layers: [
            SceneFixtures.layer(2, transform: rotation, content: .precomposition(id: 1, startFrame: 0))
        ])
        let file = try SceneFixtures.build([child, root])
        let scene = try await PreparedScene.prepare(file.composition)
        let result = try await FramePlanner.prepare(scene, at: .zero,
                                                    targetSize: PAGSize(width: 200, height: 100), scale: 2, mode: .aspectFit)
        #expect(result.plan.targetBounds == DisplayRect(x: 0, y: 0, width: 400, height: 200))
        let group = try #require(groups(result).last)
        #expect(group.clip.size == child.size)
        #expect(abs(group.clip.matrix.b - 2) < 1e-6 && abs(group.clip.matrix.c + 2) < 1e-6)
        let point = try group.clip.matrix.applying(to: ScenePoint(x: 10, y: 0))
        #expect(abs(point.x - 100) < 1e-6 && abs(point.y - 20) < 1e-6)
        #expect(solids(result).first?.matrix == group.clip.matrix)
    }

    /// 可见性编辑只隐藏指定实例；右开端点、零 alpha、零 scale 不生成纯色命令。
    @Test func visibilityAndDegenerateLayersAreCulled() async throws {
        let size = try PAGSize(width: 10, height: 10)
        let content = SourceLayerContent.solid(size: size, color: .defaultFill)
        let transparent = SourceTransformProperties(constant: SourceTransform(anchor: .zero, position: .zero,
                                                                              scale: .one, rotation: 0, opacity: 0))
        let collapsed = SourceTransformProperties(constant: SourceTransform(anchor: .zero, position: .zero,
                                                                            scale: .zero, rotation: 0, opacity: 255))
        let source = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(1, start: 0, duration: 1, content: content),
            SceneFixtures.layer(2, active: false, content: content),
            SceneFixtures.layer(3, transform: transparent, content: content),
            SceneFixtures.layer(4, transform: collapsed, content: content),
            SceneFixtures.layer(5)
        ])
        let file = try SceneFixtures.build([source])
        let first = try await prepare(file.composition)
        #expect(solids(first).map(\.layerID.path) == [[1]])
        let end = try await prepare(file.composition, frame: 1)
        #expect(solids(end).isEmpty)
        var edited = file.composition
        let layer = try EditableFixtures.layer(path: [2], in: edited)
        try edited.setVisibility(true, for: layer.id)
        let changed = try await prepare(edited, frame: 1)
        #expect(solids(changed).map(\.layerID.path) == [[2]])
        #expect(solids(end).isEmpty)
    }

    /// 尚未接入的颜色字形即使隐藏也明确失败，不能发布丢掉 emoji 的“完整计划”。
    @Test func pendingContentCannotProducePartialPlan() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        var composition = file.composition
        var text = try composition.text(at: 0)
        text.text = "😀"
        try composition.replaceText(text, at: 0)
        for layer in composition.layers { try composition.setVisibility(false, for: layer.id) }
        await #expect(throws: PAGError.unsupportedFeature("textColorGlyphs")) { try await prepare(composition) }
    }

    /// 预算不足和已经取消均不发布结果；没有实际显示目标也能独立验证计划失败语义。
    @Test func budgetAndCancellationFailAtomically() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "replacement.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        await #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try await FramePlanner.prepare(scene, at: .zero, targetSize: file.composition.size,
                                            scale: 1, mode: .none, maximumBytes: 2000)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await prepare(file.composition)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 以源逻辑尺寸和一倍像素采样指定源帧，避免测试把显示缩放混入源矩阵预期。
    private func prepare(_ composition: PAGComposition, frame: Int64 = 0) async throws -> PreparedFrame {
        let scene = try await PreparedScene.prepare(composition)
        return try await FramePlanner.prepare(scene, at: TimeMapping.time(forFrame: frame, frameRate: composition.frameRate),
                                        targetSize: composition.size, scale: 1, mode: .none)
    }

    /// 提取图片命令，仅简化断言，不改变计划中的实际排列顺序。
    private func images(_ frame: PreparedFrame) -> [FrameImage] {
        frame.plan.commands.compactMap { if case .image(let value) = $0 { value } else { nil } }
    }

    /// 提取纯色命令，返回实际覆盖顺序。
    private func solids(_ frame: PreparedFrame) -> [FrameSolid] {
        frame.plan.commands.compactMap { if case .solid(let value) = $0 { value } else { nil } }
    }

    /// 提取组开始命令，用于检查时刻、整体 alpha 和裁剪矩阵。
    private func groups(_ frame: PreparedFrame) -> [FrameGroup] {
        frame.plan.commands.compactMap { if case .beginGroup(let value) = $0 { value } else { nil } }
    }
}
