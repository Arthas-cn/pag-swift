import Foundation

/// 内嵌视频的证据化读取入口；完整场景/系统解码/Metal闭包共用这些源记录。
extension PAGSceneDecoder {
    /// 读取VideoCompositionTag的ID、字节bool和嵌套标签，不发布PAGFile或假图片层。
    mutating func readVideoComposition(reader: inout PAGByteReader) throws
        -> (id: UInt32, attributes: CompositionAttributes, video: SourceVideoComposition) {
        try budget.reserve(512)
        let id = try reader.readEncodedUInt32()
        // VideoCompositionTag读取定义ID时允许0；引用的0哨兵由共同图验证器单独处理。
        let hasAlpha = try reader.readUInt8() != 0
        var attributes: CompositionAttributes?
        var sequences: [SourceVideoSequence] = []
        var headers: [Data?] = []
        while var block = try nextBlock(from: &reader) {
            switch block.code {
            case 3:
                guard attributes == nil else { throw SceneValidator.invalid("duplicateCompositionAttributes") }
                attributes = try readCompositionAttributes(reader: &block.reader)
            case 51:
                sequences.append(try readVideoSequence(reader: &block.reader, hasAlpha: hasAlpha))
                headers.append(nil)
            case 33:
                guard let index = headers.firstIndex(where: { $0 == nil }) else {
                    throw SceneValidator.invalid("unmatchedVideoMP4Header")
                }
                // 上游按首个未绑定序列分配；原生NAL解码不需要解释或拼装此可选容器头。
                headers[index] = try readVideoBytes(reader: &block.reader)
            default:
                throw PAGError.unsupportedFeature("videoCompositionTag:\(block.code)")
            }
            try StaticAttributes.requireEnd(of: block.reader)
        }
        guard let attributes else { throw SceneValidator.invalid("missingCompositionAttributes") }
        let video = try SourceVideoComposition(sequences: sequences, mp4Headers: headers, frameRate: attributes.frameRate)
        return (id, attributes, video)
    }

    /// 按VideoSequence.cpp逐字段读取，SPS交给系统解释；PTS索引与编码顺序保持分离。
    mutating func readVideoSequence(reader: inout PAGByteReader, hasAlpha: Bool) throws -> SourceVideoSequence {
        try Task.checkCancellation()
        try budget.reserve(count: reader.remainingByteCount, stride: 2)
        var identityReader = reader
        let identity = try DocumentIdentity(data: identityReader.readData(byteCount: identityReader.remainingByteCount))
        let width = Int(try reader.readEncodedInt32())
        let height = Int(try reader.readEncodedInt32())
        let rate = try StaticAttributes.scalar(from: &reader)
        let x = try hasAlpha ? Int(reader.readEncodedInt32()) : 0
        let y = try hasAlpha ? Int(reader.readEncodedInt32()) : 0
        guard width > 0, height > 0, rate > 0, x >= 0, y >= 0 else {
            throw SceneValidator.invalid("videoSequenceHeader")
        }
        // Int32来源在64位Int相加不会溢出，先检查策略边界，再转换给CoreMedia。
        let videoWidth = (width + x + 1) / 2 * 2
        let videoHeight = (height + y + 1) / 2 * 2
        guard videoWidth <= 16_384, videoHeight <= 16_384 else {
            throw PAGError.resourceLimitExceeded("videoDimensions")
        }
        let sps = try readVideoBytes(reader: &reader)
        let pps = try readVideoBytes(reader: &reader)
        let decodedSize = try H264Format.inspect(sps: sps, pps: pps, width: videoWidth, height: videoHeight)
        let count = Int(try reader.readEncodedUInt32())
        guard count > 0 else { throw SceneValidator.invalid("emptyVideoSequence") }
        // 每样本至少PTS、长度及一个NAL字节，此外还需要关键帧位流。
        guard count <= reader.remainingByteCount / 3,
              (count + 7) / 8 <= reader.remainingByteCount - count * 3 else {
            throw PAGError.truncatedData(offset: reader.position)
        }
        try budget.reserve(count: count, stride: 256)
        var keys: [Bool] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            keys.append(try reader.readUnsignedBits(count: 1) != 0)
        }
        reader.alignToByte()
        var samples: [SourceVideoSample] = []
        var keyframes: [Int] = []
        var times: Set<Int64> = []
        for index in 0..<count {
            try Task.checkCancellation()
            let frame = try StaticAttributes.frame(from: &reader)
            guard frame >= 0, times.insert(frame).inserted else { throw SceneValidator.invalid("videoPresentationTime") }
            _ = try SceneValidator.time(frame: frame, rate: rate)
            if keys[index] {
                // 源码seek把关键帧PTS直接当编码索引，条件不成立就不能安全沿用这套时间映射。
                guard frame == Int64(index) else { throw PAGError.unsupportedFeature("videoKeyframeTimeline") }
                keyframes.append(index)
            }
            samples.append(SourceVideoSample(frame: frame, isKeyframe: keys[index], data: try readVideoBytes(reader: &reader)))
        }
        guard keyframes.first == 0 else { throw PAGError.unsupportedFeature("videoMissingInitialKeyframe") }
        let order = samples.indices.sorted { samples[$0].frame < samples[$1].frame }
        try validateVideoReordering(samples: samples, order: order)
        var ranges: [ClosedRange<Int64>] = []
        if reader.remainingByteCount > 0 {
            let rangeCount = Int(try reader.readEncodedUInt32())
            guard rangeCount <= reader.remainingByteCount / 2 else { throw PAGError.truncatedData(offset: reader.position) }
            try budget.reserve(count: rangeCount, stride: 32)
            for _ in 0..<rangeCount {
                try Task.checkCancellation()
                let start = try StaticAttributes.frame(from: &reader)
                let end = try StaticAttributes.frame(from: &reader)
                guard start >= 0, start <= end, ranges.last.map({ $0.upperBound < start }) ?? true else {
                    throw SceneValidator.invalid("videoStaticRange")
                }
                _ = try SceneValidator.time(frame: end, rate: rate)
                ranges.append(start...end)
            }
        }
        try Task.checkCancellation()
        return SourceVideoSequence(identity: identity, width: width, height: height, alphaStartX: x, alphaStartY: y,
            frameRate: rate, sps: sps, pps: pps, samples: samples, presentationOrder: order,
            keyframes: keyframes, staticRanges: ranges, decodedSize: decodedSize)
    }

    /// 读取非空长度前缀字节；其格式解释由NAL或可选容器头的使用者决定。
    private mutating func readVideoBytes(reader: inout PAGByteReader) throws -> Data {
        let length = Int(try reader.readEncodedUInt32())
        guard length > 0 else { throw SceneValidator.invalid("emptyVideoBytes") }
        try budget.reserve(length)
        return try reader.readData(byteCount: length)
    }

    /// 验证最多两个提前到达、尚未轮到输出的样本；PTS跨度大不等于解码重排深度大。
    private func validateVideoReordering(samples: [SourceVideoSample], order: [Int]) throws {
        var received = Array(repeating: false, count: samples.count)
        var expected = 0
        var pending = 0
        for index in samples.indices {
            try Task.checkCancellation()
            received[index] = true
            pending += 1
            while expected < order.count, received[order[expected]] {
                expected += 1
                pending -= 1
            }
            guard pending <= 2 else { throw PAGError.unsupportedFeature("videoReorderDepth") }
        }
    }
}
