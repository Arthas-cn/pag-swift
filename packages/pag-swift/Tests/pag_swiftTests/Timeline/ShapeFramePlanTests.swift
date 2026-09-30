import Testing
@testable import pag_swift

/// 从完整形状文件到共享几何与逐帧命令，覆盖资源复用、实例身份、编辑和整体 alpha。
struct ShapeFramePlanTests {
    /// red 的真实 group 矩阵和矩形进入实际 FramePlan，不用纯色层替代它的几何。
    @Test func realRedProducesCorrectSharedGeometry() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "red.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let first = try await renderPlan(scene)
        let later = try await renderPlan(scene, time: PAGTime(microseconds: 10_000_000))
        let command = try #require(fills(first).first)
        let laterCommand = try #require(fills(later).first)
        let geometry = try #require(first.shapes[command.geometryID])
        #expect(first.plan.commands.count == 3 && first.shapes.count == 1 && first.images.isEmpty)
        #expect(try command.material.solidColor() == .defaultFill && command.opacity == 1)
        #expect(command.geometryID == laterCommand.geometryID)
        #expect(geometry === later.shapes[laterCommand.geometryID])
        let firstContour = try #require(geometry.contours.first)
        guard case .rectangle(let contour) = firstContour else {
            Issue.record("red.pag应保留解析矩形而不是任意路径")
            return
        }
        #expect(contour.size == ScenePoint(x: 1500, y: 300))
        #expect(contour.center == .zero && contour.radius == 0 && !contour.reversed)
        let matrix = try contour.matrix.following(command.matrix)
        #expect(try matrix.applying(to: .zero) == ScenePoint(x: 360, y: 640))
        let corner = try matrix.applying(to: ScenePoint(x: -750, y: -150))
        #expect(abs(corner.x - 0.141941607) < 1e-6 && abs(corner.y - 1.723804474) < 1e-6)
        let scaled = try await FramePlanner.prepare(scene, at: .zero, targetSize: PAGSize(width: 360, height: 360),
                                                     scale: 2, mode: .aspectFit)
        let scaledCommand = try #require(fills(scaled).first)
        let displayMatrix = try contour.matrix.following(scaledCommand.matrix)
        #expect(try displayMatrix.applying(to: .zero) == ScenePoint(x: 360, y: 360))
    }

    /// 图层和 shape group 的整体 alpha 保持两层边界，内部 fill 的 opacity 不重复相乘。
    @Test func layerAndShapeOpacityRemainSeparateGroups() async throws {
        let group = SourceShapeTransform(base: transform(opacity: 128), skew: 0, skewAxis: 0)
        let contents: [SourceShape] = [.group(group, [rectangle, .fill(color: .defaultFill, opacity: 255),
                                                    .fill(color: SceneColor(red: 0, green: 0, blue: 255), opacity: 64)])]
        let layer = SceneFixtures.layer(10, transform: SourceTransformProperties(constant: transform(opacity: 192)),
                                        content: .shape(contents))
        let source = try SceneFixtures.composition(1, layers: [layer])
        let file = try SceneFixtures.build([source])
        let prepared = try await PreparedScene.prepare(file.composition)
        let frame = try await renderPlan(prepared)
        let opacities = frame.plan.commands.compactMap { command -> Double? in
            if case .beginOpacityGroup(let group) = command { group.opacity } else { nil }
        }
        #expect(opacities == [Double(192) / 255, Double(128) / 255])
        #expect(fills(frame).map(\.opacity) == [Double(64) / 255, 1])
        #expect(frame.shapes.count == 1)
        var open = 0
        var compositeGroups = 0
        for command in frame.plan.commands {
            if case .beginOpacityGroup = command { open += 1 }
            if case .endOpacityGroup = command { open -= 1 }
            if case .beginGroup = command { compositeGroups += 1 }
            #expect(open >= 0)
        }
        #expect(open == 0 && compositeGroups == 1)
    }

    /// 两个预合成实例具有不同 ID/矩阵，但同一源形状只准备一份几何并在帧表去重。
    @Test func instancesShareGeometryWithoutSharingPlacement() async throws {
        let child = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(10, content: .shape([rectangle, .fill(color: .defaultFill, opacity: 255)]))
        ])
        let root = try SceneFixtures.composition(2, layers: [
            SceneFixtures.layer(20, content: .precomposition(id: 1, startFrame: 0)),
            SceneFixtures.layer(21, transform: SourceTransformProperties(constant: transform(x: 50)),
                                content: .precomposition(id: 1, startFrame: 0))
        ])
        let file = try SceneFixtures.build([child, root])
        let prepared = try await PreparedScene.prepare(file.composition)
        let result = try await renderPlan(prepared)
        let commands = fills(result)
        #expect(prepared.shapes.count == 1 && result.shapes.count == 1 && commands.count == 2)
        #expect(commands.map(\.layerID.path) == [[21, 10], [20, 10]])
        #expect(commands[0].geometryID == commands[1].geometryID)
        #expect(commands.map(\.matrix.tx) == [50, 0])
    }

    /// 可见性编辑复用旧静态资源但保留独立快照；降低准备预算不能通过复用绕过限制。
    @Test func editsReuseGeometryAndRespectNewBudget() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "red.pag"))
        let original = try await PreparedScene.prepare(file.composition)
        var edited = file.composition
        let layer = try #require(edited.layers.first)
        try edited.setVisibility(false, for: layer.id)
        let hidden = try await PreparedScene.prepare(edited, reusing: original)
        let key = try #require(original.shapes.keys.first)
        #expect(original.shapes[key] === hidden.shapes[key])
        #expect(hidden.estimatedShapeBytes == original.estimatedShapeBytes)
        let hiddenFrame = try await renderPlan(hidden)
        let originalFrame = try await renderPlan(original)
        #expect(hiddenFrame.shapes.isEmpty && fills(hiddenFrame).isEmpty)
        #expect(originalFrame.shapes.count == 1 && fills(originalFrame).count == 1)
        await #expect(throws: PAGError.resourceLimitExceeded("maximumPreparedSceneBytes")) {
            try await PreparedScene.prepare(edited, reusing: original, maximumBytes: original.estimatedShapeBytes - 1)
        }
    }

    /// 同内容新存储仍重新验证准备；不能用测试语义图的相同摘要误复用另一个源层。
    @Test func differentStorageDoesNotReuseUnrelatedPreparation() async throws {
        let firstSource = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(1, content: .shape([rectangle, .fill(color: .defaultFill, opacity: 255)]))
        ])
        let secondSource = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(1, content: .shape([rectangle, .fill(color: SceneColor(red: 0, green: 0, blue: 255), opacity: 255)]))
        ])
        let firstFile = try SceneFixtures.build([firstSource])
        let secondFile = try SceneFixtures.build([secondSource])
        let first = try await PreparedScene.prepare(firstFile.composition)
        let second = try await PreparedScene.prepare(secondFile.composition, reusing: first)
        let key = try #require(first.shapes.keys.first)
        #expect(first.shapes[key] !== second.shapes[key])
        let result = try await renderPlan(second)
        #expect(try fills(result).first?.material.solidColor() == SceneColor(red: 0, green: 0, blue: 255))
    }

    /// 场景准备和逐帧表各自执行预算与取消门禁，不把后台失败转成空白成功。
    @Test func preparationAndPlanFailuresAreExplicit() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "red.pag"))
        await #expect(throws: PAGError.resourceLimitExceeded("maximumPreparedSceneBytes")) {
            try await PreparedScene.prepare(file.composition, maximumBytes: 1)
        }
        let scene = try await PreparedScene.prepare(file.composition)
        await #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try await FramePlanner.prepare(scene, at: .zero, targetSize: file.composition.size,
                                             scale: 1, mode: .none, maximumBytes: 1500)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PreparedScene.prepare(file.composition, reusing: scene)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 不增加显示缩放的源帧求值，便于单独断言源几何与图层位置。
    private func renderPlan(_ scene: PreparedScene, time: PAGTime = .zero) async throws -> PreparedFrame {
        try await FramePlanner.prepare(scene, at: time, targetSize: scene.composition.size, scale: 1, mode: .none)
    }

    /// 提取当前计划中的全部形状 fill，保持覆盖顺序。
    private func fills(_ frame: PreparedFrame) -> [FrameShape] {
        frame.plan.commands.compactMap { if case .shape(let shape) = $0 { shape } else { nil } }
    }

    /// 语义图中使用的中心矩形，不携带颜色或透明度。
    private var rectangle: SourceShape {
        .rectangle(reversed: false, size: ScenePoint(x: 20, y: 20), position: .zero, roundness: 0)
    }

    /// 创建只有水平位移和自身 opacity 的层/组变换。
    private func transform(x: Double = 0, opacity: UInt8 = 255) -> SourceTransform {
        SourceTransform(anchor: .zero, position: ScenePoint(x: x, y: 0), scale: .one, rotation: 0, opacity: opacity)
    }
}
