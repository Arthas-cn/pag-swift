import Foundation
import UniformTypeIdentifiers

/// 文件级字体、图片、允许索引与缩放表读取，字段来自 libpag 对应 tags/ 文件。
extension PAGSceneDecoder {
    /// FontTables.cpp 按表内顺序分配从零开始的 ID，每条含两个零终止字符串。
    mutating func readFonts(reader: inout PAGByteReader) throws {
        let count = Int(try reader.readEncodedUInt32())
        guard count <= reader.remainingByteCount / 2 else { throw PAGError.truncatedData(offset: reader.position) }
        try budget.reserve(count: count, stride: 128)
        for index in 0..<count {
            try Task.checkCancellation()
            resources.fonts[UInt32(index)] = SourceFont(family: try reader.readUTF8String(), style: try reader.readUTF8String())
        }
    }

    /// ImageTables.cpp 先读数量，再连续读取 ImageBytes V1 记录，不包含内部标签头。
    mutating func readImageTable(reader: inout PAGByteReader) throws {
        let count = Int(try reader.readEncodedUInt32())
        guard count <= reader.remainingByteCount / 2 else { throw PAGError.truncatedData(offset: reader.position) }
        for _ in 0..<count { try readImage(code: 47, reader: &reader) }
    }

    /// ImageBytes/V2/V3：ID、带长度字节，再按版本读取 scale/逻辑尺寸/裁边 anchor。
    mutating func readImage(code: UInt16, reader: inout PAGByteReader) throws {
        try Task.checkCancellation()
        try budget.reserve(256)
        let id = try reader.readEncodedUInt32()
        guard resources.images[id] == nil else { throw SceneValidator.invalid("duplicateImageID") }
        let count = Int(try reader.readEncodedUInt32())
        guard count > 0 else { throw SceneValidator.invalid("emptyImageBytes") }
        let data = try reader.readData(byteCount: count)
        let scale = try code >= 48 ? StaticAttributes.scalar(from: &reader) : 1
        guard scale > 0 else { throw SceneValidator.invalid("invalidImageScale") }
        var explicitSize: PAGSize?
        var anchor = ScenePoint.zero
        if code == 49 {
            let width = try reader.readEncodedInt32()
            let height = try reader.readEncodedInt32()
            guard width > 0, height > 0 else { throw SceneValidator.invalid("invalidImageSize") }
            explicitSize = try PAGSize(width: Double(width), height: Double(height))
            anchor = try ScenePoint(x: Double(reader.readEncodedInt32()), y: Double(reader.readEncodedInt32()))
        }
        let image = try StillImageDecoder.decode(data, identity: DocumentIdentity(data: data),
                                                maximumDecodedBytes: budget.limit - budget.used)
        // 上游 V1/V2 的尺寸来自 WebPGetInfo；不能把任意 ImageIO 格式装成合法 PAG 内图片。
        guard image.storage.sourceType == UTType.webP.identifier else {
            // V3 直接读取逻辑尺寸，没有 V1/V2 的 WebPGetInfo 限制；其他格式语义尚未验收。
            if code == 49 { throw PAGError.unsupportedFeature("embeddedImageFormat") }
            throw SceneValidator.invalid("embeddedImageIsNotWebP")
        }
        guard image.storage.sourceOrientation == 1 else { throw PAGError.unsupportedFeature("embeddedImageOrientation") }
        let width = (image.size.width / scale).rounded()
        let height = (image.size.height / scale).rounded()
        guard explicitSize != nil || (width >= 1 && height >= 1 && width <= Double(Int32.max) && height <= Double(Int32.max)) else {
            throw SceneValidator.invalid("invalidScaledImageSize")
        }
        let logicalSize = try explicitSize ?? PAGSize(width: width, height: height)
        try budget.reserve(image.storage.pixels.count)
        resources.images[id] = SourceImage(id: id, image: image, logicalSize: logicalSize, scaleFactor: scale, anchor: anchor)
    }

    /// EditableIndices.cpp 依次存图片、文本允许索引；显式 count=0 不等于标签缺失。
    mutating func readEditableIndices(reader: inout PAGByteReader) throws {
        guard resources.allowedImages == nil, resources.allowedTexts == nil else {
            throw SceneValidator.invalid("duplicateEditableIndices")
        }
        resources.allowedImages = try readIndices(reader: &reader)
        resources.allowedTexts = try readIndices(reader: &reader)
    }

    /// 按ImageScaleModes.cpp读取单份tag94；未知模式、重复、截断、预算或取消均不发布列表。
    mutating func readImageScaleModes(reader: inout PAGByteReader) throws {
        try Task.checkCancellation()
        guard resources.imageScaleModes == nil else { throw SceneValidator.invalid("duplicateImageScaleModes") }
        let count = Int(try reader.readEncodedUInt32())
        // 每个编码枚举至少占一个字节，先限制计数才能进入可取消循环及分配。
        guard count <= reader.remainingByteCount else { throw PAGError.truncatedData(offset: reader.position) }
        try budget.reserve(count: count, stride: 16)
        var modes: [PAGScaleMode] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            let raw = try reader.readEncodedUInt32()
            switch raw {
            case 0: modes.append(.none)
            case 1: modes.append(.stretch)
            case 2: modes.append(.aspectFit)
            case 3: modes.append(.aspectFill)
            default: throw PAGError.unsupportedFeature("imageScaleMode:\(raw)")
            }
        }
        try StaticAttributes.requireEnd(of: reader)
        try Task.checkCancellation()
        resources.imageScaleModes = modes
    }

    /// 读取带符号索引列表，范围与唯一性在源槽位建立后统一验证。
    private mutating func readIndices(reader: inout PAGByteReader) throws -> [Int] {
        let count = Int(try reader.readEncodedUInt32())
        guard count <= reader.remainingByteCount else { throw PAGError.truncatedData(offset: reader.position) }
        try budget.reserve(count: count, stride: 16)
        var result: [Int] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            result.append(Int(try reader.readEncodedInt32()))
        }
        return result
    }
}
