@testable import pag_swift

/// 字体准备与计划测试共用的语义文本，不拼接假的完整 PAG 字节。
enum TextFixtures {
    /// 构造指定文字及少量内部源样式；默认使用系统 PingFang SC，实际回退保留诊断。
    static func source(_ text: String = "AA", direction: UInt8 = 0, fauxBold: Bool = false, fauxItalic: Bool = false,
                       strokeOverFill: Bool = true, backgroundAlpha: UInt8 = 0, style: PAGText? = nil) throws -> SourceText {
        let value = try style ?? PAGText(text: text, fontSize: 24, fontFamily: "PingFang SC", fontStyle: "Medium",
                                         fillColor: PAGColor(red: 0, green: 0, blue: 0))
        return SourceText(style: value, baselineShift: 0, firstBaseline: 0, isBoxText: false,
                          boxPosition: .zero, boxSize: .zero, fauxBold: fauxBold, fauxItalic: fauxItalic,
                          strokeOverFill: strokeOverFill, justification: 0, backgroundColor: SceneColor(red: 255, green: 255, blue: 255),
                          backgroundAlpha: backgroundAlpha, direction: direction)
    }

    /// 在明确的非主 actor 调用中执行同步准备，只返回 Sendable 值和不可变路径。
    @concurrent static func prepare(_ source: SourceText, maximumBytes: Int = 64 * 1024 * 1024) async throws -> PreparedTextLayer {
        var budget = FramePlanBudget(limit: maximumBytes, resourceName: "maximumPreparedSceneBytes")
        return try TextPreparation.prepare(source, style: source.style, budget: &budget)
    }
}
