import Foundation

/// 一个已划定边界的语义块；游标仅在当前解码调用内使用。
struct SceneTagBlock {
    /// include/pag/file.h::TagCode 中的编码值。
    let code: UInt16
    /// 当前标签的独立载荷边界。
    var reader: PAGByteReader
}

/// 完整支持子集的解码器，包含静态内容与二维动画轨道；未知语义失败，不能发布部分文档。
struct PAGSceneDecoder {
    /// 此次载入使用的资源限制。
    let limits: PAGLoadLimits
    /// 分配前扣减的保守逻辑内存预算。
    var budget: DecodeBudget
    /// 已读取的源图层数，所有合成共用同一上限。
    var sourceLayerCount = 0
    /// 当前文件的字体、图片和允许编辑集合，完成验证后发布为只读资源。
    var resources = SourceResources()
    /// nil表示尚未遇到tag32，成功读取后保留设置并拒绝重复单值元数据。
    var fileTiming: SourceFileTiming?

    /// 后台验证完整字节并构建只读场景；取消保留 CancellationError。
    /// identity 仅可来自对同一完整 data 的内部快照准备；nil 时自行计算摘要。
    @concurrent static func decode(_ data: Data, limits: PAGLoadLimits = .standard,
                                   identity: DocumentIdentity? = nil) async throws -> PAGFile {
        let inspection = try await PAGContainerInspector.inspect(data, limits: limits)
        try Task.checkCancellation()
        var decoder = PAGSceneDecoder(limits: limits, budget: DecodeBudget(limit: limits.maximumDecodedBytes))
        // 同时计入输入快照、读取器副本、探查标签和后续字符串的保守空间。
        try decoder.budget.reserve(count: data.count, stride: 3)
        try decoder.budget.reserve(count: inspection.tags.count, stride: 64)
        var reader = PAGByteReader(data: data)
        try reader.skip(byteCount: inspection.bodyRange.lowerBound)
        var body = try reader.readSubreader(byteCount: inspection.bodyRange.count)
        var compositions: [SourceComposition] = []
        var hasMetadata = false
        var hasFonts = false
        while var block = try decoder.nextBlock(from: &body) {
            switch block.code {
            case 1:
                guard !hasFonts else { throw SceneValidator.invalid("duplicateFontTable") }
                hasFonts = true
                try decoder.readFonts(reader: &block.reader)
            case 4:
                try decoder.readImageTable(reader: &block.reader)
            case 47, 48, 49:
                try decoder.readImage(code: block.code, reader: &block.reader)
            case 83:
                try decoder.readEditableIndices(reader: &block.reader)
            case 94:
                try decoder.readImageScaleModes(reader: &block.reader)
            case 2, 45:
                compositions.append(try decoder.readComposition(reader: &block.reader, isBitmap: block.code == 45))
            case 50:
                let value = try decoder.readVideoComposition(reader: &block.reader)
                compositions.append(SourceComposition(id: value.id, size: value.attributes.size,
                    durationFrames: value.attributes.duration, frameRate: value.attributes.frameRate,
                    background: value.attributes.background, layers: [], video: value.video))
            case 31:
                guard !hasMetadata else { throw PAGError.invalidFile(reason: "duplicateFileAttributes", offset: nil) }
                hasMetadata = true
                try decoder.readFileAttributes(reader: &block.reader)
            case 32:
                try decoder.readFileTiming(reader: &block.reader)
            default:
                throw PAGError.unsupportedFeature("fileTag:\(block.code)")
            }
            try StaticAttributes.requireEnd(of: block.reader)
        }
        // Loader 已为本次完整快照计算摘要时复用；独立内部调用仍自行计算，禁止由 public 传入。
        let documentIdentity = try identity ?? DocumentIdentity(data: data)
        return try SceneValidator.build(compositions: compositions, identity: documentIdentity,
                                        limits: limits, budget: &decoder.budget, resources: decoder.resources,
                                        fileTiming: decoder.fileTiming ?? SourceFileTiming())
    }

    /// 消费一个标签并分离载荷；nil 仅表示当前位置正好是容器末尾的 End。
    mutating func nextBlock(from reader: inout PAGByteReader) throws -> SceneTagBlock? {
        try Task.checkCancellation()
        try budget.reserve(64)
        let header = try PAGTagHeader.read(from: &reader)
        if header.code == 0 {
            // 与顶层一样，任何嵌套 End 之后都不允许藏未解释的语义字节。
            try StaticAttributes.requireEnd(of: reader)
            return nil
        }
        return SceneTagBlock(code: header.code, reader: try reader.readSubreader(byteCount: header.payloadRange.count))
    }

    /// 按 Vector/BitmapCompositionTag 读取 ID 和标签；共同属性必须恰好一次，内容不可混用。
    private mutating func readComposition(reader: inout PAGByteReader, isBitmap: Bool) throws -> SourceComposition {
        try budget.reserve(512)
        let id = try reader.readEncodedUInt32()
        var attributes: CompositionAttributes?
        var layers: [SourceLayer] = []
        var sequences: [SourceBitmapSequence] = []
        while var block = try nextBlock(from: &reader) {
            switch block.code {
            case 3:
                guard attributes == nil else { throw PAGError.invalidFile(reason: "duplicateCompositionAttributes", offset: nil) }
                attributes = try readCompositionAttributes(reader: &block.reader)
            case 5 where !isBitmap:
                layers.append(try readLayer(reader: &block.reader))
            case 46 where isBitmap:
                sequences.append(try readBitmapSequence(reader: &block.reader))
            default:
                throw PAGError.unsupportedFeature("compositionTag:\(block.code)")
            }
            try StaticAttributes.requireEnd(of: block.reader)
        }
        guard let attributes else { throw PAGError.invalidFile(reason: "missingCompositionAttributes", offset: nil) }
        let bitmap = try isBitmap ? SourceBitmapComposition(sequences: sequences, frameRate: attributes.frameRate) : nil
        return SourceComposition(id: id, size: attributes.size, durationFrames: attributes.duration,
                                 frameRate: attributes.frameRate, background: attributes.background, layers: layers, bitmap: bitmap)
    }

    /// 按 CompositionAttributes.cpp 固定字段顺序读取；这些字段没有属性 flags。
    func readCompositionAttributes(reader: inout PAGByteReader) throws -> CompositionAttributes {
        let width = try reader.readEncodedInt32()
        let height = try reader.readEncodedInt32()
        let duration = try StaticAttributes.frame(from: &reader)
        let frameRate = try StaticAttributes.scalar(from: &reader)
        let background = try StaticAttributes.color(from: &reader)
        guard width > 0, height > 0, duration > 0, frameRate > 0 else {
            throw PAGError.invalidFile(reason: "invalidCompositionAttributes", offset: nil)
        }
        return CompositionAttributes(size: try PAGSize(width: Double(width), height: Double(height)),
                                     duration: duration, frameRate: frameRate, background: background)
    }

    /// 验证 FileAttributes.cpp 的非画面元数据，允许不保留这些字符串。
    private func readFileAttributes(reader: inout PAGByteReader) throws {
        _ = try reader.readEncodedInt64()
        for _ in 0..<5 { _ = try reader.readUTF8String() }
        let warnings = Int(try reader.readEncodedUInt32())
        // 每个字符串至少需要结束零字节；先拒绝攻击性计数，避免无输入的长循环。
        guard warnings <= reader.remainingByteCount else { throw PAGError.truncatedData(offset: reader.position) }
        for _ in 0..<warnings {
            try Task.checkCancellation()
            _ = try reader.readUTF8String()
        }
    }
}

/// CompositionAttributes 的暂存值；通过标签单次性检查后组装源合成。
struct CompositionAttributes: Sendable {
    /// 经过正值验证的逻辑尺寸。
    let size: PAGSize
    /// 文件中的正帧时长。
    let duration: Int64
    /// 文件中的有限正帧率。
    let frameRate: Double
    /// 三通道背景元数据，不是显示目标 clear color。
    let background: SceneColor
}
