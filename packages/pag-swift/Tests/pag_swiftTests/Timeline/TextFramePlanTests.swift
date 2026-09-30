import Testing
@testable import pag_swift

/// 真实文本和编辑快照从 Loader/语义场景进入 FramePlan；不把计划通过当作 GPU 已显示。
struct TextFramePlanTests {
    /// 完整 TEXT04 使用真实字体/字形并生成两轮计划，跨帧共享资源而不是重新排版。
    @Test func realTextFileProducesSharedStrokeThenFillPlan() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        let first = try await frame(scene)
        let later = try await frame(scene, time: PAGTime(microseconds: 10_000_000))
        let commands = texts(first)
        #expect(commands.count == 2 && first.plan.commands.count == 4)
        #expect(commands.map(\.passIndex) == [0, 1] && first.texts.count == 1)
        let prepared = try #require(first.texts[commands[0].resourceID])
        #expect(prepared === later.texts[commands[0].resourceID])
        #expect(prepared.glyphs.count == 9 && prepared.layout.lines.count == 1)
        #expect(prepared.layout.glyphScale == 1 && prepared.fonts[0].postScriptName == "PingFangSC-Medium")
        // 源框 x=−93.75、宽187.5；实际字体 nominal 总宽179.328，居中后的首/末位置可独立算出。
        #expect(abs(prepared.glyphs[0].matrix.tx + 89.664) < 0.002)
        #expect(abs(prepared.glyphs[8].matrix.tx - 65.664) < 0.002)
        #expect(prepared.glyphs.allSatisfy { abs($0.matrix.ty + 5.528076171875) < 0.0001 })
        #expect(prepared.glyphs.allSatisfy { !$0.fill.elements.isEmpty && !($0.stroke?.elements.isEmpty ?? true) })
        guard case .stroke(let stroke) = prepared.passes[0], case .fill(let fill) = prepared.passes[1] else {
            Issue.record("TEXT04 要求先描边后填充")
            return
        }
        #expect(stroke == prepared.style.strokeColor && fill == prepared.style.fillColor)
    }

    /// 修改文字创建新代数，原帧保持旧资源；恢复原值可显式复用保存的原始准备对象。
    @Test func replacementInvalidatesOnlyChangedTextAndOldFramesStayValid() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        let original = try await PreparedScene.prepare(file.composition)
        let oldFrame = try await frame(original)
        let key = try #require(original.texts.keys.first)
        let oldText = try #require(original.texts[key])
        var composition = file.composition
        var text = try composition.text(at: 0)
        text.text = "AA"
        text.strokeColor = nil
        try composition.replaceText(text, at: 0)
        let edited = try await PreparedScene.prepare(composition, reusing: original)
        let newText = try #require(edited.texts[key])
        #expect(newText !== oldText && newText.identity != oldText.identity)
        #expect(newText.glyphs.count == 2 && newText.glyphs[0].fill === newText.glyphs[1].fill)
        #expect(oldFrame.texts[oldText.identity]?.glyphs.count == 9)
        try composition.replaceText(nil, at: 0)
        let restored = try await PreparedScene.prepare(composition, reusing: original)
        #expect(restored.texts[key] === oldText)
    }

    /// 同源预合成实例共享文本路径/布局，但独立的层矩阵和实例身份不能串用。
    @Test func repeatedInstancesShareTextButKeepTheirPlacement() async throws {
        let sourceText = try TextFixtures.source("A")
        let child = try SceneFixtures.composition(1, layers: [SceneFixtures.layer(10, content: .text(sourceText))])
        let transform = SourceTransform(anchor: .zero, position: ScenePoint(x: 50, y: 0), scale: .one, rotation: 0, opacity: 255)
        let root = try SceneFixtures.composition(2, layers: [
            SceneFixtures.layer(20, content: .precomposition(id: 1, startFrame: 0)),
            SceneFixtures.layer(21, transform: SourceTransformProperties(constant: transform), content: .precomposition(id: 1, startFrame: 0))
        ])
        let file = try SceneFixtures.build([child, root])
        let prepared = try await PreparedScene.prepare(file.composition)
        let result = try await frame(prepared)
        let commands = texts(result)
        #expect(result.texts.count == 1 && commands.count == 2)
        #expect(commands.map(\.layerID.path) == [[21, 10], [20, 10]])
        #expect(commands.map(\.matrix.tx) == [50, 0] && commands[0].resourceID == commands[1].resourceID)
    }

    /// 图层 alpha 包住两轮文字，不分摊到 fill/stroke；只有根合成添加 clip。
    @Test func textLayerOpacityWrapsBothPassesWithoutBoxClip() async throws {
        var style = try TextFixtures.source().style
        style.strokeColor = try PAGColor(red: 1, green: 0, blue: 0)
        style.strokeWidth = 2
        let text = try TextFixtures.source(style: style)
        let transform = SourceTransform(anchor: .zero, position: .zero, scale: .one, rotation: 0, opacity: 128)
        let root = try SceneFixtures.composition(1, layers: [
            SceneFixtures.layer(10, transform: SourceTransformProperties(constant: transform), content: .text(text))
        ])
        let scene = try await PreparedScene.prepare(SceneFixtures.build([root]).composition)
        let result = try await frame(scene)
        #expect(result.plan.commands.count == 6 && texts(result).count == 2)
        guard case .beginOpacityGroup(let group) = result.plan.commands[1], case .endOpacityGroup = result.plan.commands[4] else {
            Issue.record("文本整体 alpha 必须包住两次绘制")
            return
        }
        #expect(group.opacity == Double(128) / 255)
        #expect(result.plan.commands.filter { if case .beginGroup = $0 { true } else { false } }.count == 1)
    }

    /// 可见性编辑复用文本；重用路径也必须通过新预算，取消不能发布迟到结果。
    @Test func visibilityReuseBudgetAndCancellationRemainIndependent() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        let original = try await PreparedScene.prepare(file.composition)
        let key = try #require(original.texts.keys.first)
        let text = try #require(original.texts[key])
        var composition = file.composition
        try composition.setVisibility(false, for: #require(composition.layers.first).id)
        let hidden = try await PreparedScene.prepare(composition, reusing: original)
        #expect(hidden.texts[key] === text)
        #expect(try await frame(hidden).texts.isEmpty)
        await #expect(throws: PAGError.resourceLimitExceeded("maximumPreparedSceneBytes")) {
            try await PreparedScene.prepare(composition, reusing: original, maximumBytes: text.estimatedBytes - 1)
        }
        await #expect(throws: PAGError.resourceLimitExceeded("maximumFramePlanBytes")) {
            try await FramePlanner.prepare(original, at: .zero, targetSize: file.composition.size, scale: 1, mode: .none, maximumBytes: 1500)
        }
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PreparedScene.prepare(file.composition, reusing: original)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 使用源逻辑大小请求确定性计划，不挂载平台宿主或申请 drawable。
    private func frame(_ scene: PreparedScene, time: PAGTime = .zero) async throws -> PreparedFrame {
        try await FramePlanner.prepare(scene, at: time, targetSize: scene.composition.size, scale: 1, mode: .none)
    }

    /// 提取文本命令并保留原 pass 顺序，其他内容继续由对应测试覆盖。
    private func texts(_ frame: PreparedFrame) -> [FrameText] {
        frame.plan.commands.compactMap { if case .text(let value) = $0 { value } else { nil } }
    }
}
