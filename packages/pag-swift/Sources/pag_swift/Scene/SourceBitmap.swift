import Foundation

/// bitmap 合成的只读素材与静态区间；不创建可编辑图片图层。
struct SourceBitmapComposition: Sendable {
    /// 编码顺序的全部序列，验证完成后按上游规则使用最后一条。
    let sequences: [SourceBitmapSequence]
    /// 最高帧率序列推导的合成帧闭区间；区间内统一采样起点。
    let staticRanges: [ClosedRange<Int64>]

    /// 根据上游 BitmapComposition::updateStaticTimeRanges 建立区间；不可表示的时间失败。
    init(sequences: [SourceBitmapSequence], frameRate: Double) throws {
        guard var highest = sequences.first else { throw SceneValidator.invalid("missingBitmapSequence") }
        for sequence in sequences.dropFirst() where sequence.frameRate > highest.frameRate { highest = sequence }
        let scale = Float(frameRate) / Float(highest.frameRate)
        guard scale.isFinite, scale > 0 else { throw SceneValidator.invalid("bitmapTimeScale") }
        var ranges: [ClosedRange<Int64>] = []
        var start = 0
        var end = 0
        for (index, frame) in highest.frames.enumerated() {
            try Task.checkCancellation()
            if frame.isEmpty {
                end = index
            } else {
                if end > start { ranges.append(try Self.range(start: start, end: end, scale: scale)) }
                start = index
                end = index
            }
        }
        if end > start { ranges.append(try Self.range(start: start, end: end, scale: scale)) }
        self.sequences = sequences
        staticRanges = ranges
    }

    /// 先折叠静态区间再转换帧率，返回末序列中的合法索引；调用方已钳制合成帧。
    func frameIndex(at frame: Int64, frameRate: Double) throws -> Int {
        guard let sequence = sequences.last, frame >= 0 else { throw SceneValidator.invalid("bitmapFrame") }
        // 与上游 FindTimeRangeAt 一样命中中点即停止；roundf 后区间端点可能重合。
        var lower = 0
        var upper = staticRanges.count - 1
        var mapped = frame
        while lower <= upper {
            let middle = lower + (upper - lower) / 2
            let range = staticRanges[middle]
            if range.lowerBound > frame { upper = middle - 1 }
            else if range.upperBound < frame { lower = middle + 1 }
            else {
                mapped = range.lowerBound
                break
            }
        }
        let scale = Double(Float(sequence.frameRate) / Float(frameRate))
        let value = (Double(mapped) * scale).rounded()
        guard value.isFinite, value >= 0 else { throw SceneValidator.invalid("bitmapTimeScale") }
        if value >= Double(sequence.frames.count - 1) { return sequence.frames.count - 1 }
        return Int(value)
    }

    /// 保留上游 roundf 的 Float32 运算顺序，不用 Double 改写半帧边界。
    private static func range(start: Int, end: Int, scale: Float) throws -> ClosedRange<Int64> {
        guard let first = Int64(exactly: (Float(start) * scale).rounded()),
              let last = Int64(exactly: (Float(end) * scale).rounded()), first <= last else {
            throw SceneValidator.invalid("bitmapStaticRange")
        }
        return first...last
    }
}

/// 一条经过字节和矩形边界验证的 bitmap 序列，压缩输入按需解码。
struct SourceBitmapSequence: Sendable {
    /// 整个编码序列的摘要，尺寸、帧率、帧标记和矩形字节均参与身份。
    let identity: DocumentIdentity
    /// 正像素宽度，不超过内部输入资源限制。
    let width: Int
    /// 正像素高度，不超过内部输入资源限制。
    let height: Int
    /// 文件 Float32 帧率扩为 Double 保存，不重新量化。
    let frameRate: Double
    /// 至少一帧，顺序即解码/显示顺序。
    let frames: [SourceBitmapFrame]
    /// 每帧最近关键帧索引；首帧之前不存在关键帧时从透明画布的第0帧开始。
    let starts: [Int]
    /// 最大矩形 RGBA 字节数，用于解码前预留暂存预算。
    let maximumPatchBytes: Int

    /// 完整 RGBA8 基底的字节数，解码阶段已验证乘法范围。
    var byteCount: Int { width * height * 4 }

    /// 派生稳定输入身份，不扫描每次重建的整幅像素，也不把微秒作为帧身份。
    func imageIdentity(at index: Int) throws -> DocumentIdentity {
        var bytes = Data("pag.bitmap.frame.v1".utf8)
        bytes.append(contentsOf: identity.digest)
        var frame = UInt64(index).littleEndian
        withUnsafeBytes(of: &frame) { bytes.append(contentsOf: $0) }
        return try DocumentIdentity(data: bytes)
    }
}

/// 单个时刻的有序覆盖矩形；空帧保留此前基底。
struct SourceBitmapFrame: Sendable {
    /// 是否允许从此帧开始独立重建，沿用编码的 keyframe bit。
    let isKeyframe: Bool
    /// 按编码顺序覆盖，不进行透明度混合。
    let patches: [SourceBitmapPatch]
    /// 上游历史空帧判定；不是只判断 patches 是否为空。
    var isEmpty: Bool {
        patches.allSatisfy { $0.x == 0 && $0.y == 0 && $0.data.count <= 150 && $0.width <= 1 && $0.height <= 1 }
    }
}

/// 源素材的一个静态 WebP 矩形；坐标已验证完整落在序列画布内。
struct SourceBitmapPatch: Sendable {
    /// 画布左上原点下的非负像素横坐标。
    let x: Int
    /// 画布左上原点下的非负像素纵坐标。
    let y: Int
    /// 头元数据中的正像素宽度，实际解码时再次核对。
    let width: Int
    /// 头元数据中的正像素高度，实际解码时再次核对。
    let height: Int
    /// 不包含长度前缀的完整静态 WebP 字节；不是解码像素。
    let data: Data
}
