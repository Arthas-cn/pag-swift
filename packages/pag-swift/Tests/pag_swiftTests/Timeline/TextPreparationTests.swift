import CoreGraphics
import CoreText
import Testing
@testable import pag_swift

/// 系统整形转纯值资源的行为，覆盖实际字体、路径、方向、回退和明确能力边界。
struct TextPreparationTests {
    /// 重复 glyph 共享同一轮廓，空格/换行保留布局但不产生路径命令。
    @Test func repeatedGlyphsShareOutlinesWithoutLosingWhitespaceLayout() async throws {
        let prepared = try await TextFixtures.prepare(TextFixtures.source("A A\nA"))
        #expect(prepared.glyphs.count == 3 && prepared.layout.glyphs.count == 4 && prepared.layout.lines.count == 2)
        #expect(prepared.glyphs[0].fill === prepared.glyphs[1].fill && prepared.glyphs[1].fill === prepared.glyphs[2].fill)
        #expect(prepared.glyphs[0].matrix.tx < prepared.glyphs[1].matrix.tx)
        #expect(prepared.glyphs[2].matrix.ty > prepared.glyphs[0].matrix.ty)
        #expect(prepared.glyphs.map(\.cluster) == [0..<1, 2..<3, 4..<5])
        #expect(prepared.fonts.count == 1 && prepared.fonts[0].family == "PingFang SC")
        #expect(!prepared.fonts[0].substitutesRequest && prepared.missingGlyphIndices.isEmpty)
    }

    /// 描边/填充保持完整轮次，零填充与阈值以下的纯描边不暗中恢复黑色文字。
    @Test func paintPassesAndThinStrokeFollowSourceSemantics() async throws {
        var style = try PAGText(text: "A", fontSize: 24, fontFamily: "PingFang SC",
                                fillColor: PAGColor(red: 1, green: 0, blue: 0),
                                strokeColor: PAGColor(red: 0, green: 0, blue: 1), strokeWidth: 3)
        let over = try await TextFixtures.prepare(TextFixtures.source(style: style))
        let under = try await TextFixtures.prepare(TextFixtures.source(strokeOverFill: false, style: style))
        #expect(kinds(over) == ["fill", "stroke"] && kinds(under) == ["stroke", "fill"])
        #expect(!(try #require(over.glyphs.first?.stroke)).elements.isEmpty)
        style.strokeWidth = 0.01
        let thin = try await TextFixtures.prepare(TextFixtures.source(style: style))
        #expect(kinds(thin) == ["fill"] && thin.glyphs.first?.stroke == nil)
        style.fillColor = nil
        let strokeOnly = try await TextFixtures.prepare(TextFixtures.source(style: style))
        #expect(strokeOnly.passes.isEmpty)
        style.strokeColor = nil
        let noInk = try await TextFixtures.prepare(TextFixtures.source(style: style))
        #expect(noInk.passes.isEmpty)
    }

    /// 伪粗斜体改变轮廓而不切换成另一款 Bold 字体，排版 advance 保持不变。
    @Test func fauxStylesPrepareGeometryWithoutChangingTypefaceOrAdvance() async throws {
        let ordinary = try await TextFixtures.prepare(TextFixtures.source())
        let italic = try await TextFixtures.prepare(TextFixtures.source(fauxItalic: true))
        let bold = try await TextFixtures.prepare(TextFixtures.source(fauxBold: true))
        #expect(ordinary.fonts.first?.postScriptName == italic.fonts.first?.postScriptName)
        #expect(ordinary.fonts.first?.postScriptName == bold.fonts.first?.postScriptName)
        #expect(ordinary.glyphs[1].matrix.tx == italic.glyphs[1].matrix.tx && ordinary.glyphs[1].matrix.tx == bold.glyphs[1].matrix.tx)
        #expect(ordinary.glyphs[0].fill.elements != italic.glyphs[0].fill.elements)
        #expect(ordinary.glyphs[0].fill.elements != bold.glyphs[0].fill.elements)
    }

    /// 竖排中文保持直立并使用字体原点，ASCII 单独旋转；两种线性矩阵分别分组。
    @Test func verticalCJKAndASCIIUseDistinctGlyphTransforms() async throws {
        let prepared = try await TextFixtures.prepare(TextFixtures.source("中A", direction: 2))
        #expect(prepared.glyphs.count == 2 && prepared.layout.glyphs.count == 2)
        let chinese = prepared.glyphs[0].matrix
        let latin = prepared.glyphs[1].matrix
        #expect(chinese.a == 1 && chinese.b == 0 && chinese.c == 0 && chinese.d == 1)
        #expect(abs(chinese.tx + 12) < 0.0001 && abs(chinese.ty - 20.64) < 0.001)
        #expect(latin.a == 0 && latin.b == 1 && latin.c == -1 && latin.d == 0)
        #expect(abs(latin.ty - 24) < 0.0001 && latin.tx < 0)
    }

    /// 固定后端把中文字形的字体 bounds 向外取整再扩1，不能误用未取整的 CoreText rect。
    @Test func glyphMetricsKeepUpstreamAntialiasingBoundsAllowance() throws {
        let source = try TextFixtures.source("中")
        let font = CTFontCreateWithName("PingFangSC-Medium" as CFString, 24, nil)
        var code: UniChar = 0x4e2d
        var glyph: CGGlyph = 0
        #expect(CTFontGetGlyphsForCharacters(font, &code, &glyph, 1))
        var budget = FramePlanBudget(limit: 64 * 1024 * 1024)
        let geometry = try SystemGlyphGeometry.prepare(font: font, id: glyph, source: source, style: source.style, budget: &budget)
        #expect(geometry.bounds == TextLayoutBounds(left: 1, top: -21, right: 23, bottom: 4))
        #expect(geometry.advance == 24 && geometry.verticalAdvance == 24)
        #expect(abs(geometry.verticalOffset.x + 12) < 0.0001 && abs(geometry.verticalOffset.y - 20.64) < 0.001)
    }

    /// 不存在的请求字体进入系统级联并留下实际诊断，非 BMP 与 RTL cluster 不发生索引下溢。
    @Test func fallbackAndUnicodeClustersRemainDiagnosable() async throws {
        let style = try PAGText(text: "A中", fontSize: 24, fontFamily: "PAG-Missing-Font-18917",
                                fillColor: PAGColor(red: 0, green: 0, blue: 0))
        let fallback = try await TextFixtures.prepare(TextFixtures.source(style: style))
        #expect(!fallback.fonts.isEmpty && fallback.fonts.allSatisfy(\.substitutesRequest))
        #expect(fallback.glyphs.count == 2)
        let music = try await TextFixtures.prepare(TextFixtures.source("𝄞A"))
        #expect(Set(music.glyphs.map(\.cluster)) == Set([0..<2, 2..<3]))
        let arabic = try await TextFixtures.prepare(TextFixtures.source("مرحبا"))
        #expect(arabic.glyphs.count == 5)
        #expect(arabic.glyphs.map(\.cluster.lowerBound) == [4, 3, 2, 1, 0])
        #expect(arabic.glyphs.allSatisfy { !$0.fill.elements.isEmpty })
    }

    /// 待实现的颜色字体与背景明确失败；空文本没有背景路径，允许清空可编辑内容。
    @Test func pendingResourcesFailAndEmptyTextClearsContent() async throws {
        await #expect(throws: PAGError.unsupportedFeature("textColorGlyphs")) {
            try await TextFixtures.prepare(TextFixtures.source("😀"))
        }
        await #expect(throws: PAGError.unsupportedFeature("textBackground")) {
            try await TextFixtures.prepare(TextFixtures.source(backgroundAlpha: 128))
        }
        let empty = try await TextFixtures.prepare(TextFixtures.source("", backgroundAlpha: 128))
        #expect(empty.glyphs.isEmpty && empty.passes.isEmpty && empty.layout.bounds == nil)
    }

    /// 输入与路径预算先于数组增长校验，已取消后台准备不发布系统调用的迟到结果。
    @Test func preparationBudgetsAndCancellationAreExplicit() async throws {
        let source = try TextFixtures.source()
        await #expect(throws: PAGError.resourceLimitExceeded("maximumPreparedSceneBytes")) {
            try await TextFixtures.prepare(source, maximumBytes: 100)
        }
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TextFixtures.prepare(source)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// 路径保留二次/三次曲线及关闭轮廓，只在值提取处翻转 y，不提前做屏幕细分。
    @Test func pathExtractionPreservesCurveKindsAndRejectsBudgetOverflow() throws {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 1, y: 2))
        path.addQuadCurve(to: CGPoint(x: 5, y: 6), control: CGPoint(x: 3, y: 4))
        path.addCurve(to: CGPoint(x: 11, y: 12), control1: CGPoint(x: 7, y: 8), control2: CGPoint(x: 9, y: 10))
        path.closeSubpath()
        var budget = FramePlanBudget(limit: 4096, resourceName: "maximumPreparedSceneBytes")
        let outline = try GlyphOutline.copy(path, budget: &budget)
        #expect(outline.elements == [.move(ScenePoint(x: 1, y: -2)),
                                     .quadratic(control: ScenePoint(x: 3, y: -4), end: ScenePoint(x: 5, y: -6)),
                                     .cubic(first: ScenePoint(x: 7, y: -8), second: ScenePoint(x: 9, y: -10), end: ScenePoint(x: 11, y: -12)), .close])
        var tiny = FramePlanBudget(limit: 300, resourceName: "maximumPreparedSceneBytes")
        #expect(throws: PAGError.resourceLimitExceeded("maximumPreparedSceneBytes")) { try GlyphOutline.copy(path, budget: &tiny) }
    }

    /// 重复/逆序 UTF-16 索引使用逻辑右邻边界，代理对中间索引被拒绝。
    @Test func clusterMappingHandlesRepeatedAndSurrogateIndices() throws {
        var budget = FramePlanBudget(limit: 4096)
        let map = try TextClusters(text: "𝄞ab", indices: [3, 2, 0, 0], budget: &budget)
        #expect(try map.cluster(at: 0).range == 0..<2)
        #expect(try map.cluster(at: 2).range == 2..<3)
        #expect(try map.cluster(at: 3).range == 3..<4)
        #expect(throws: SceneValidator.invalid("invalidTextCluster")) {
            try TextClusters(text: "𝄞", indices: [1], budget: &budget)
        }
    }

    /// 仅抽取绘制轮次种类，保持测试独立于颜色与轮廓的存储细节。
    private func kinds(_ prepared: PreparedTextLayer) -> [String] {
        prepared.passes.map { if case .fill = $0 { "fill" } else { "stroke" } }
    }
}
