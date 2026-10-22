import Testing
@testable import pag_swift

/// 显式文本框裁剪、原字号溢出滚动和独立辅助时间的生产帧计划。
struct MarqueeTests {
    /// 非法速度、间隔或等待在构造边界被拒绝，避免把非有限位移送入Metal。
    @Test func optionsRejectInvalidMotion() throws {
        #expect(throws: PAGError.invalidArgument("marqueeSpeed")) { try PAGMarqueeOptions(speed: 0) }
        #expect(throws: PAGError.invalidArgument("marqueeSpeed")) { try PAGMarqueeOptions(speed: .infinity) }
        #expect(throws: PAGError.invalidArgument("marqueeGap")) { try PAGMarqueeOptions(gap: -1) }
        #expect(throws: PAGError.invalidArgument("marqueeInitialDelay")) {
            try PAGMarqueeOptions(initialDelay: PAGTime(microseconds: -1))
        }
    }

    /// 未溢出的文字沿原排版，显式clip才增加局部裁剪；原快照不受COW编辑影响。
    @Test func clipAndFittingMarqueePreserveSourceLayout() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        var clipped = file.composition
        let source = clipped
        try clipped.setTextOverflow(.clip, at: 0)
        #expect(source.edits.textOverflows.isEmpty)
        let scene = try await PreparedScene.prepare(clipped)
        let result = try await frame(scene, playing: false, active: 0)
        #expect(result.plan.commands.contains { if case .beginGroup(let group) = $0 {
            return group.layerID != nil && group.clip.size.width == 187.5
        } else { return false } })
        let options = try PAGMarqueeOptions(speed: 100)
        try clipped.setTextOverflow(.marquee(options), at: 0)
        let fitted = try await PreparedScene.prepare(clipped, reusing: scene)
        #expect(fitted.marqueeWidths.isEmpty)
        let fittedFrame = try await frame(fitted, playing: true, active: 1_000_000)
        #expect(fittedFrame.marqueeIDs.isEmpty)
        #expect(textMatrices(fittedFrame).count == 2)
        #expect(throws: PAGError.invalidEditableIndex(-1)) {
            try clipped.setTextOverflow(.clip, at: -1)
        }
    }

    /// 长文字使用未缩小的单行资源，首次GPU激活后按累计播放时间移动且跨seek不回零。
    @Test func overflowMovesTwoClippedCopiesAfterActivation() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        var edited = file.composition
        var style = try edited.text(at: 0)
        style.text = String(repeating: "A", count: 40)
        try edited.replaceText(style, at: 0)
        let options = try PAGMarqueeOptions(speed: 100, gap: 20,
            initialDelay: PAGTime(microseconds: 100_000))
        try edited.setTextOverflow(.marquee(options), at: 0)
        let scene = try await PreparedScene.prepare(edited)
        let width = try #require(scene.marqueeWidths.values.first)
        #expect(width > 187.5)
        let first = try await frame(scene, playing: true, active: 1_000_000)
        let id = try #require(first.marqueeIDs.first)
        #expect(!textMatrices(first).isEmpty && first.marqueeIDs.count == 1)
        #expect(!first.plan.commands.contains { if case .beginPicture = $0 { true } else { false } })
        scene.marqueeClock?.activate(first.marqueeIDs, at: PAGTime(microseconds: 1_000_000))
        let waiting = try await frame(scene, playing: true, active: 1_050_000)
        #expect(textMatrices(waiting) == textMatrices(first))
        let moved = try await frame(scene, playing: true, active: 1_350_000)
        let firstX = try #require(textMatrices(first).first?.tx)
        let movedX = try #require(textMatrices(moved).first?.tx)
        #expect(abs((firstX - movedX) - 25) < 0.01)
        #expect(scene.marqueeClock?.elapsed(for: id, at: PAGTime(microseconds: 1_350_000)) ==
            PAGTime(microseconds: 350_000))
        let frozen = try await frame(scene, playing: false, active: 1_350_000)
        #expect(textMatrices(frozen) == textMatrices(moved) && frozen.marqueeIDs.isEmpty)
        scene.marqueeClock?.reset()
        let rewound = try await frame(scene, playing: true, active: 0)
        #expect(textMatrices(rewound) == textMatrices(first))
    }

    /// 通过正式求值入口取文字矩阵与播放时钟，避免只测试纯数学函数。
    private func frame(_ scene: PreparedScene, playing: Bool, active: Int64) async throws -> PreparedFrame {
        try await FramePlanner.prepare(scene, at: .zero, targetSize: scene.composition.size,
            scale: 1, mode: .none, isPlaying: playing,
            auxiliaryTime: PAGTime(microseconds: active))
    }

    /// 收集实际文字绘制轮次的图层矩阵，用来观察两个副本是否同向连续移动。
    private func textMatrices(_ frame: PreparedFrame) -> [SceneAffine] {
        frame.plan.commands.compactMap { if case .text(let value) = $0 { value.matrix } else { nil } }
    }
}
