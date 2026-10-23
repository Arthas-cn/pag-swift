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

    /// 单 tag 文字更新只重置该源槽，其它源槽的多个实例保留已累计的滚动时间。
    @Test func changingOneTagPreservesOtherActivationTimes() async throws {
        let file = try await EditableFixtures.file()
        var composition = file.composition
        let options = try PAGMarqueeOptions(speed: 50)
        for tag in ["text:0", "text:1"] {
            try await composition.apply(.text(String(repeating: "A", count: 50), layout: .marquee(options)), forTag: tag)
        }
        let original = try await PreparedScene.prepare(composition)
        let originalClock = try #require(original.marqueeClock)
        let firstIDs = try #require(composition.dynamicSlotRecords().first { $0.slot.tag == "text:0" })
            .instances.map { composition.storage.instances[$0].id }
        let secondRecord = try #require(composition.dynamicSlotRecords().first { $0.slot.tag == "text:1" })
        let secondIndex = try #require(secondRecord.instances.first)
        let secondID = composition.storage.instances[secondIndex].id
        originalClock.activate(firstIDs + [secondID], at: PAGTime(microseconds: 100_000))
        try await composition.apply(.text(String(repeating: "B", count: 50), layout: .marquee(options)), forTag: "text:1")
        let edited = try await PreparedScene.prepare(composition, reusing: original)
        let clock = try #require(edited.marqueeClock)
        for id in firstIDs {
            #expect(clock.elapsed(for: id, at: PAGTime(microseconds: 300_000)).microseconds == 200_000)
        }
        #expect(clock.elapsed(for: secondID, at: PAGTime(microseconds: 300_000)) == .zero)
        #expect(originalClock.elapsed(for: secondID, at: PAGTime(microseconds: 300_000)).microseconds == 200_000)
    }

    /// 某实例在有效完成帧中缺席时冻结，重新出现接着累计，不把隐藏间隔算作滚动时间。
    @Test func invisibleSlotFreezesIndependently() async throws {
        let file = try await EditableFixtures.file()
        let first = try EditableFixtures.layer(path: [21, 10], in: file.composition).id
        let second = try EditableFixtures.layer(path: [23], in: file.composition).id
        let clock = PresentationActivationClock()
        clock.activate([first, second], at: PAGTime(microseconds: 100))
        clock.activate([second], at: PAGTime(microseconds: 200))
        #expect(clock.elapsed(for: first, at: PAGTime(microseconds: 900)).microseconds == 100)
        #expect(clock.elapsed(for: second, at: PAGTime(microseconds: 900)).microseconds == 800)
        clock.activate([first, second], at: PAGTime(microseconds: 900))
        #expect(clock.elapsed(for: first, at: PAGTime(microseconds: 1000)).microseconds == 200)
        #expect(clock.elapsed(for: second, at: PAGTime(microseconds: 1000)).microseconds == 900)
    }

    /// 新快照准备完但旧快照才首次激活时，未改变的槽仍能收到同一次有效起点。
    @Test func retainedClockReceivesActivationDuringPreparation() async throws {
        let file = try await EditableFixtures.file()
        let id = try EditableFixtures.layer(path: [21, 10], in: file.composition).id
        let original = PresentationActivationClock()
        let copied = original.retaining([id])
        original.activate([id], at: PAGTime(microseconds: 500))
        #expect(copied.elapsed(for: id, at: PAGTime(microseconds: 700)).microseconds == 200)
        copied.reset()
        #expect(copied.elapsed(for: id, at: PAGTime(microseconds: 700)) == .zero)
        #expect(original.elapsed(for: id, at: PAGTime(microseconds: 700)).microseconds == 200)
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
