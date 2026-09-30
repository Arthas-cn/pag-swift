import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 内嵌 bitmap 字节读取；依据 libpag BitmapSequence.cpp，不接受外部视频容器。
extension PAGSceneDecoder {
    /// 读取序列头、连续关键帧位和各帧矩形；所有分配先计量，取消不返回半条序列。
    mutating func readBitmapSequence(reader: inout PAGByteReader) throws -> SourceBitmapSequence {
        try budget.reserve(count: reader.remainingByteCount, stride: 2)
        var identityReader = reader
        let identity = try DocumentIdentity(data: identityReader.readData(byteCount: identityReader.remainingByteCount))
        let width = Int(try reader.readEncodedInt32())
        let height = Int(try reader.readEncodedInt32())
        let rate = try StaticAttributes.scalar(from: &reader)
        guard width > 0, height > 0, rate > 0 else { throw SceneValidator.invalid("bitmapSequenceHeader") }
        guard width <= 16_384, height <= 16_384,
              UInt128(width) * UInt128(height) <= UInt128(limits.maximumDecodedBytes / 4) else {
            throw PAGError.resourceLimitExceeded("bitmapDimensions")
        }
        let count = Int(try reader.readEncodedUInt32())
        guard count > 0 else { throw SceneValidator.invalid("emptyBitmapSequence") }
        // 每帧至少有一个矩形数量字节，此外还必须留出 ceil(count/8) 个 keyframe 位字节。
        guard count <= reader.remainingByteCount,
              (count + 7) / 8 <= reader.remainingByteCount - count else {
            throw PAGError.truncatedData(offset: reader.position)
        }
        try budget.reserve(count: count, stride: 128)
        var keys: [Bool] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            keys.append(try reader.readUnsignedBits(count: 1) != 0)
        }
        reader.alignToByte()
        var frames: [SourceBitmapFrame] = []
        var starts: [Int] = []
        var start = 0
        var maximumPatchBytes = 0
        for index in 0..<count {
            try Task.checkCancellation()
            let patchCount = Int(try reader.readEncodedUInt32())
            guard patchCount <= reader.remainingByteCount / 4 else { throw PAGError.truncatedData(offset: reader.position) }
            try budget.reserve(count: patchCount, stride: 128)
            var patches: [SourceBitmapPatch] = []
            for _ in 0..<patchCount {
                let patch = try readBitmapPatch(reader: &reader, width: width, height: height)
                maximumPatchBytes = max(maximumPatchBytes, patch.width * patch.height * 4)
                patches.append(patch)
            }
            if keys[index] { start = index }
            starts.append(start)
            frames.append(SourceBitmapFrame(isKeyframe: keys[index], patches: patches))
        }
        return SourceBitmapSequence(identity: identity, width: width, height: height, frameRate: rate,
                                    frames: frames, starts: starts, maximumPatchBytes: maximumPatchBytes)
    }

    /// 验证坐标与静态图头，保留压缩字节；不在载入期间展开整个动画像素。
    private mutating func readBitmapPatch(reader: inout PAGByteReader, width: Int, height: Int) throws -> SourceBitmapPatch {
        try Task.checkCancellation()
        let x = Int(try reader.readEncodedInt32())
        let y = Int(try reader.readEncodedInt32())
        let length = Int(try reader.readEncodedUInt32())
        guard length > 0 else { throw SceneValidator.invalid("emptyBitmapPatch") }
        guard x >= 0, y >= 0, x < width, y < height else { throw SceneValidator.invalid("bitmapPatchBounds") }
        try budget.reserve(length)
        let data = try reader.readData(byteCount: length)
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let rawType = CGImageSourceGetType(source) else { throw PAGError.mediaFailure("bitmapPatchHeader") }
        guard rawType as String == UTType.webP.identifier else { throw PAGError.unsupportedFeature("bitmapPatchFormat") }
        guard CGImageSourceGetCount(source) == 1 else { throw PAGError.unsupportedFeature("animatedBitmapPatch") }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let rawHeight = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
              let patchWidth = Int(exactly: rawWidth.doubleValue), let patchHeight = Int(exactly: rawHeight.doubleValue),
              patchWidth > 0, patchHeight > 0, patchWidth <= width - x, patchHeight <= height - y else {
            throw SceneValidator.invalid("bitmapPatchBounds")
        }
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        guard orientation == 1 else { throw PAGError.unsupportedFeature("bitmapPatchOrientation") }
        try Task.checkCancellation()
        return SourceBitmapPatch(x: x, y: y, width: patchWidth, height: patchHeight, data: data)
    }
}
