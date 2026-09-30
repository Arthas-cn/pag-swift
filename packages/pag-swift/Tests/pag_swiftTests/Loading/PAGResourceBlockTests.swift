import Foundation
import Testing
@testable import pag_swift

/// 真实资源子块及明确损坏变体；子块通过不意味着其所属复杂文件已经完整支持。
struct PAGResourceBlockTests {
    /// 真实 V1 字体/文本片段消费到边界，保留文本框和描边覆盖关系等内部排版字段。
    @Test func readsCompleteTextBlock() throws {
        let data = try PAGFixtures.data(named: "editing/TEXT04.pag")
        var decoder = decoder()
        var fonts = PAGByteReader(data: Data(data[64..<84]))
        try decoder.readFonts(reader: &fonts)
        try StaticAttributes.requireEnd(of: fonts)
        var text = PAGByteReader(data: Data(data[140..<199]))
        let value = try decoder.readText(code: 8, reader: &text)
        try StaticAttributes.requireEnd(of: text)
        #expect(value.isBoxText && !value.strokeOverFill)
        #expect(value.justification == 1 && value.direction == 0 && value.backgroundAlpha == 0)
        #expect(value.style.text == "04.这是一个字幕")
    }

    /// 真实V3片段保留垂直方向和背景透明度；完整文件由ShapeGeneratorFilePlaybackTests另验。
    @Test func readsVerticalTextFragment() throws {
        let data = try PAGFixtures.data(named: "TextDirection.pag")
        var decoder = decoder()
        var fonts = PAGByteReader(data: Data(data[66..<124]))
        try decoder.readFonts(reader: &fonts)
        var text = PAGByteReader(data: Data(data[199..<264]))
        let value = try decoder.readText(code: 68, reader: &text)
        try StaticAttributes.requireEnd(of: text)
        #expect(value.direction == 2 && value.backgroundAlpha == 0)
        #expect(value.isBoxText && value.style.text == "竖排框文本12单行")
        #expect(value.style.fontFamily == "PingFang SC")
    }

    /// 外层属性缺失与内层字段缺失具有不同默认值，尤其 V3 的方向不可混用。
    @Test(arguments: [UInt16(8), 64, 68])
    func textVersionDefaultsAreDistinct(_ code: UInt16) throws {
        let decoder = decoder()
        var absent = PAGByteReader(data: Data([0]))
        let outer = try decoder.readText(code: code, reader: &absent)
        #expect(outer.style.fillColor != nil && outer.strokeOverFill)
        #expect(outer.backgroundAlpha == (code == 64 ? 255 : 0))
        #expect(outer.direction == (code == 68 ? 1 : 0))
        // 源码配置的独立属性片段：存在且静态，随后所有内层 flags 都为零；不是完整 PAG 文件。
        var inner = PAGByteReader(data: Data([1, 0, 0, 0]))
        let value = try decoder.readText(code: code, reader: &inner)
        #expect(value.style.fillColor == nil && !value.strokeOverFill)
        #expect(value.style.fontSize == 24 && value.style.strokeWidth == 1)
        #expect(value.backgroundAlpha == (code == 8 ? 0 : 255))
        #expect(value.direction == (code == 68 ? 2 : 0))
    }

    /// 未安装字体引用及被标为动画的真实文本片段必须失败，不能替换为默认字体/首帧。
    @Test func invalidTextReferencesAndAnimationFail() throws {
        let data = try PAGFixtures.data(named: "editing/TEXT04.pag")
        let decoder = decoder()
        var missingFont = PAGByteReader(data: Data(data[140..<199]))
        #expect(throws: SceneValidator.invalid("missingFontReference")) {
            try decoder.readText(code: 8, reader: &missingFont)
        }
        var animated = Data(data[140..<199])
        animated[0] = 3
        var reader = PAGByteReader(data: animated)
        #expect(throws: PAGError.unsupportedFeature("animatedProperty")) { try decoder.readText(code: 8, reader: &reader) }
    }

    /// 真实 V3 裁边元数据被保留，不能被编码像素尺寸覆盖或丢弃 anchor。
    @Test func readsImageV3Fragment() throws {
        let data = try PAGFixtures.data(named: "wstask_prizebaoji.pag")
        var decoder = decoder()
        var reader = PAGByteReader(data: Data(data[39..<3562]))
        try decoder.readImage(code: 49, reader: &reader)
        try StaticAttributes.requireEnd(of: reader)
        let image = try #require(decoder.resources.images.values.first)
        #expect(image.id == 1_426_696 && image.scaleFactor == 1)
        #expect(image.logicalSize == (try PAGSize(width: 100, height: 100)))
        #expect(image.anchor == ScenePoint(x: -8, y: 0))
    }

    /// 同一 ID 重复、空载荷和非法 scale 都是损坏输入；每个子块不越界消费。
    @Test func invalidImageRecordsFail() throws {
        let data = try PAGFixtures.data(named: "editing/replace.pag")
        let record = Data(data[16515..<117851])
        var decoder = decoder()
        var first = PAGByteReader(data: record)
        try decoder.readImage(code: 48, reader: &first)
        var duplicate = PAGByteReader(data: record)
        #expect(throws: SceneValidator.invalid("duplicateImageID")) { try decoder.readImage(code: 48, reader: &duplicate) }
        var emptyDecoder = self.decoder()
        var empty = PAGByteReader(data: Data([1, 0]))
        #expect(throws: SceneValidator.invalid("emptyImageBytes")) { try emptyDecoder.readImage(code: 47, reader: &empty) }
        var zeroScale = record
        zeroScale.replaceSubrange((zeroScale.count - 4)..<zeroScale.count, with: [0, 0, 0, 0])
        var invalid = PAGByteReader(data: zeroScale)
        #expect(throws: SceneValidator.invalid("invalidImageScale")) { try emptyDecoder.readImage(code: 48, reader: &invalid) }
    }

    /// V1/V2 明确要求 WebP，V3 其他格式尚未验收，应区分格式无效与未支持。
    @Test func embeddedImageFormatErrorsFollowVersionEvidence() throws {
        let png = try PAGFixtures.data(named: "media/rgba-corners.png")
        // 独立资源片段，仅用于未支持/错误路径；长度小于 128，ByteData 长度只有一个字节。
        try #require(png.count < 128)
        let record = Data([1, UInt8(png.count)]) + png
        var first = decoder()
        var v1 = PAGByteReader(data: record)
        #expect(throws: SceneValidator.invalid("embeddedImageIsNotWebP")) { try first.readImage(code: 47, reader: &v1) }
        var third = decoder()
        var v3 = PAGByteReader(data: record + Data([0, 0, 128, 63, 4, 4, 0, 0]))
        #expect(throws: PAGError.unsupportedFeature("embeddedImageFormat")) { try third.readImage(code: 49, reader: &v3) }
    }

    /// 修改真实图像引用到不存在的资源时，完整载入失败而不是留下空图片层。
    @Test func missingImageReferenceFailsWholeDocument() async throws {
        var data = try PAGFixtures.data(named: "editing/ImageDecodeTest.pag")
        data[34163] = 99
        await #expect(throws: SceneValidator.invalid("missingImageReference")) {
            try await PAGSceneDecoder.decode(data)
        }
    }

    /// 上游 EditableIndices 的顺序为图片后文本；存在但为空仍是显式允许空集合。
    @Test func editableListsPreservePresenceAndOrder() throws {
        var decoder = decoder()
        // 独立源码证据片段：两项图片 [1,3]，一项文本 [2]；有符号索引采用低位符号编码。
        var reader = PAGByteReader(data: Data([2, 2, 6, 1, 4]))
        try decoder.readEditableIndices(reader: &reader)
        #expect(decoder.resources.allowedImages == [1, 3])
        #expect(decoder.resources.allowedTexts == [2])
        var duplicate = PAGByteReader(data: Data([0, 0]))
        #expect(throws: SceneValidator.invalid("duplicateEditableIndices")) { try decoder.readEditableIndices(reader: &duplicate) }
        var emptyDecoder = self.decoder()
        var empty = PAGByteReader(data: Data([0, 0]))
        try emptyDecoder.readEditableIndices(reader: &empty)
        #expect(emptyDecoder.resources.allowedImages == [] && emptyDecoder.resources.allowedTexts == [])
    }

    /// 资源读取不能用超大计数驱动无输入循环，也不能绕过像素预算。
    @Test func resourceBudgetsAndCountsAreBounded() throws {
        var decoder = decoder()
        var fonts = PAGByteReader(data: Data([0xff, 0xff, 0xff, 0xff, 0x0f]))
        #expect(throws: PAGError.truncatedData(offset: 5)) { try decoder.readFonts(reader: &fonts) }
        var images = PAGByteReader(data: Data([0xff, 0xff, 0xff, 0xff, 0x0f]))
        #expect(throws: PAGError.truncatedData(offset: 5)) { try decoder.readImageTable(reader: &images) }
        var indices = PAGByteReader(data: Data([0xff, 0xff, 0xff, 0xff, 0x0f]))
        #expect(throws: PAGError.truncatedData(offset: 5)) { try decoder.readEditableIndices(reader: &indices) }
        let data = try PAGFixtures.data(named: "editing/ImageDecodeTest.pag")
        var image = PAGByteReader(data: Data(data[60..<11959]))
        var tiny = PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: 512))
        #expect(throws: PAGError.resourceLimitExceeded("maximumDecodedBytes")) { try tiny.readImage(code: 47, reader: &image) }
    }

    /// 每个片段测试使用独立资源上下文，避免其他测试先安装字体或图片掩盖问题。
    private func decoder() -> PAGSceneDecoder {
        PAGSceneDecoder(limits: .standard, budget: DecodeBudget(limit: PAGLoadLimits.standard.maximumDecodedBytes))
    }
}
