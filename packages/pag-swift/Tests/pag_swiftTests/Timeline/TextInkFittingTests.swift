import CoreGraphics
import Testing
@testable import pag_swift

/// 动态单行文字按真实轮廓适配，覆盖中英文、重音、下伸部、描边和策略切换。
struct TextInkFittingTests {
    /// TEXT04 的长文字在截断和跑马灯中都应完整落在原框高度内，不能切掉中英文顶部或下伸部。
    @Test(arguments: ["PAG Swift 动态文字", "ÁÉgjpqy 中文"])
    func realFileKeepsInkInsideBox(_ fragment: String) async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        for layout in [DynamicTextLayout.truncate, .marquee(try PAGMarqueeOptions())] {
            var composition = file.composition
            try await composition.apply(.text(String(repeating: fragment, count: 8), layout: layout), forTag: "text:0")
            let scene = try await PreparedScene.prepare(composition)
            let text = try #require(scene.texts.values.first)
            let source = try sourceText(scene, reference: text.source)
            let ink = try measure(text)
            let baseline = scene.marqueeWidths[text.source] == nil ? 0 : source.firstBaseline
            #expect(ink.minY + baseline >= source.boxPosition.y + 0.49)
            #expect(ink.maxY + baseline <= source.boxPosition.y + source.boxSize.y - 0.49)
            if case .truncate = layout {
                #expect(text.style.text.hasSuffix("…"))
                #expect(ink.minX >= source.boxPosition.x + 0.49)
                #expect(ink.maxX <= source.boxPosition.x + source.boxSize.x - 0.49)
            } else {
                #expect(scene.marqueeWidths[text.source] != nil)
                #expect(text.layout.lines.count == 1)
            }
        }
    }

    /// 粗描边超出字体逻辑边界时也必须完整适配，而不是只测 fill 或 ascent/descent。
    @Test func thickStrokeAndShortTextAreFittedWithoutScrolling() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        var composition = file.composition
        var style = try composition.text(at: 0)
        style.strokeWidth = 12
        try composition.replaceText(style, at: 0)
        try await composition.apply(.text("Ágj", layout: .marquee(try PAGMarqueeOptions())), forTag: "text:0")
        let scene = try await PreparedScene.prepare(composition)
        let text = try #require(scene.texts.values.first)
        let source = try sourceText(scene, reference: text.source)
        #expect(scene.marqueeWidths.isEmpty)
        let ink = try measure(text)
        #expect(ink.minY >= source.boxPosition.y + 0.49)
        #expect(ink.maxY <= source.boxPosition.y + source.boxSize.y - 0.49)
        #expect(text.glyphs.allSatisfy { $0.stroke != nil })
    }

    /// 原字号很高、适配高度后宽度已能放下时应静止单行，不能回退框排版而意外折行。
    @Test func tallMarqueeThatFitsAfterScalingRemainsOneLine() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        var composition = file.composition
        var style = try composition.text(at: 0)
        style.fontSize = 120
        try composition.replaceText(style, at: 0)
        try await composition.apply(.text("AAAA", layout: .marquee(try PAGMarqueeOptions())), forTag: "text:0")
        let scene = try await PreparedScene.prepare(composition)
        let text = try #require(scene.texts.values.first)
        #expect(scene.marqueeWidths.isEmpty)
        #expect(text.layout.lines.count == 1 && text.glyphs.count == 4)
        let source = try sourceText(scene, reference: text.source)
        let ink = try measure(text)
        #expect(ink.minY >= source.boxPosition.y + 0.49)
        #expect(ink.maxY <= source.boxPosition.y + source.boxSize.y - 0.49)
    }

    /// 从截断切回自动模式必须复原源排版矩阵；低层 clip 也继续明确按原框裁剪。
    @Test func automaticAndExplicitClipKeepOriginalLayout() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "editing/TEXT04.pag"))
        let value = String(repeating: "PAG 动态文字 ", count: 5)
        var composition = file.composition
        try await composition.apply(.text(value, layout: .truncate), forTag: "text:0")
        let truncated = try await PreparedScene.prepare(composition)
        try await composition.apply(.text(value, layout: .automatic), forTag: "text:0")
        let automatic = try await PreparedScene.prepare(composition, reusing: truncated)
        let text = try #require(automatic.texts.values.first)
        let source = try sourceText(automatic, reference: text.source)
        var budget = FramePlanBudget(limit: 64 * 1024 * 1024)
        let original = try TextPreparation.prepare(source, reference: text.source, style: text.style, budget: &budget)
        #expect(text.glyphs.map(\.matrix) == original.glyphs.map(\.matrix))
        try composition.setTextOverflow(.clip, at: 0)
        let clipped = try await PreparedScene.prepare(composition, reusing: automatic)
        #expect(clipped.texts.values.first?.glyphs.map(\.matrix) == original.glyphs.map(\.matrix))
    }

    /// 真实加载的图层源字段是框位置与高度的依据，不在测试中复制 TEXT04 的硬编码尺寸。
    private func sourceText(_ scene: PreparedScene, reference: SourceLayerReference) throws -> SourceText {
        let layer = scene.composition.storage.compositions[reference.composition].layers[reference.layer]
        guard case .text(let source) = layer.content else { throw PAGError.invalidArgument("testTextSource") }
        return source
    }

    /// 使用轮廓而非字体逻辑范围测量，确保回归会发现描边越界。
    private func measure(_ text: PreparedTextLayer) throws -> CGRect {
        var budget = FramePlanBudget(limit: 64 * 1024 * 1024)
        return try #require(TextInkFitting.bounds(of: text, budget: &budget))
    }
}
