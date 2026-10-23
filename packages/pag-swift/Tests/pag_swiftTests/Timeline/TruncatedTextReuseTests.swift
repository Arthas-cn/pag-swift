import Foundation
import Testing
@testable import pag_swift

/// 截断文字的场景复用和失效边界；资源身份用于确认没有重新整形和生成字形。
struct TruncatedTextReuseTests {
    /// 可见性编辑不改变输入文字或布局，应复用已截断结果并保留完整业务文字。
    @Test func visibilityEditReusesTruncatedText() async throws {
        var composition = try await composition()
        let original = try await PreparedScene.prepare(composition)
        let text = try #require(original.texts.values.first)
        try #require(text.style.text.hasSuffix("…"))
        try composition.setVisibility(false, for: #require(composition.layers.first).id)
        let hidden = try await PreparedScene.prepare(composition, reusing: original)
        #expect(hidden.texts[text.source] === text)
        #expect(try composition.text(at: 0).text != text.style.text)
    }

    /// 相同可见前缀不能代替完整输入身份；文字尾部或颜色变化仍须重新准备。
    @Test func changedTextAndStyleInvalidateReuse() async throws {
        var composition = try await composition()
        let original = try await PreparedScene.prepare(composition)
        let text = try #require(original.texts.values.first)
        var style = try composition.text(at: 0)
        style.text += " changed suffix"
        try composition.replaceText(style, at: 0)
        let changed = try await PreparedScene.prepare(composition, reusing: original)
        let changedText = try #require(changed.texts[text.source])
        #expect(changedText !== text)
        style.fillColor = try PAGColor(red: 1, green: 0, blue: 0)
        try composition.replaceText(style, at: 0)
        let recolored = try await PreparedScene.prepare(composition, reusing: changed)
        #expect(recolored.texts[text.source] !== changedText)
        #expect(recolored.texts[text.source]?.style.fillColor == style.fillColor)
    }

    /// 从截断切回自动排版应恢复完整文字；再次准备相同自动布局可复用新结果。
    @Test func layoutChangeInvalidatesTruncation() async throws {
        var composition = try await composition()
        let original = try await PreparedScene.prepare(composition)
        let text = try #require(original.texts.values.first)
        try composition.setTextOverflow(nil, at: 0)
        let automatic = try await PreparedScene.prepare(composition, reusing: original)
        let restored = try #require(automatic.texts[text.source])
        #expect(restored !== text)
        #expect(restored.style.text == (try composition.text(at: 0).text))
        let repeated = try await PreparedScene.prepare(composition, reusing: automatic)
        #expect(repeated.texts[text.source] === restored)
    }

    /// 截断缓存命中仍遵守新场景预算与取消，不能将命中当成免校验入口。
    @Test func reuseChecksBudgetAndCancellation() async throws {
        let composition = try await composition()
        let original = try await PreparedScene.prepare(composition)
        let text = try #require(original.texts.values.first)
        await #expect(throws: PAGError.resourceLimitExceeded("maximumPreparedSceneBytes")) {
            try await PreparedScene.prepare(composition, reusing: original, maximumBytes: text.estimatedBytes - 1)
        }
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PreparedScene.prepare(composition, reusing: original)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 显式测量同文档截断结果的重复准备成本；仅报告 CPU 时间，不设机器相关通过门槛。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PAG_TEXT_REUSE_BENCHMARK"] == "1",
                   "设置 PAG_TEXT_REUSE_BENCHMARK=1 测量截断文字复用"))
    func recordsRepeatedPreparationCost() async throws {
        let composition = try await composition()
        let original = try await PreparedScene.prepare(composition)
        var milliseconds: [Double] = []
        var reused = 0
        for index in 0..<35 {
            let start = ContinuousClock.now
            let next = try await PreparedScene.prepare(composition, reusing: original)
            let elapsed = start.duration(to: .now).components
            // 首五次只预热；同一素材和输入保持不变，比较的只有准备通路。
            if index >= 5 {
                milliseconds.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
                if next.texts.values.first === original.texts.values.first { reused += 1 }
            }
        }
        let sorted = milliseconds.sorted()
        #expect(sorted.count == 30)
        print("PAG_TEXT_REUSE samples=30 reused=\(reused) median_ms=\(sorted[15]) p95_ms=\(sorted[28]) max_ms=\(sorted[29])")
    }

    /// 使用真实框文字文件及长业务内容，确保实际进入省略号准备而非普通文字快路径。
    private func composition() async throws -> PAGComposition {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        var composition = file.composition
        try await composition.apply(.text(String(repeating: "PAG Swift ", count: 12), layout: .truncate), forTag: "text:0")
        return composition
    }
}
