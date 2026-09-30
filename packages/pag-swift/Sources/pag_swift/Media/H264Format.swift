import CoreMedia
import Foundation

/// owner域内的H.264系统描述；不遵循Sendable，不将原始CoreMedia对象送入场景图。
final class H264Format {
    /// 完整保留avcC等扩展并明确PAG色彩的系统输入描述。
    let description: CMVideoFormatDescription
    /// SPS给出的正像素尺寸；输入区域与实际输出缓冲仍须分别检查。
    let size: PAGSize

    /// 用系统解析SPS/PPS并核对声明边界；不支持的显式颜色、损坏NAL和预算分别失败。
    init(sps: Data, pps: Data, width: Int, height: Int) throws {
        try Task.checkCancellation()
        guard sps.first.map({ $0 & 31 == 7 }) == true,
              pps.first.map({ $0 & 31 == 8 }) == true else { throw PAGError.mediaFailure("h264ParameterSets") }
        var parsed: CMVideoFormatDescription?
        let status = try sps.withUnsafeBytes { first in
            try pps.withUnsafeBytes { second in
                guard let firstPointer = first.bindMemory(to: UInt8.self).baseAddress,
                      let secondPointer = second.bindMemory(to: UInt8.self).baseAddress else {
                    throw PAGError.mediaFailure("h264ParameterSets")
                }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: [firstPointer, secondPointer],
                    parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &parsed
                )
            }
        }
        guard status == noErr, let parsed else { throw PAGError.mediaFailure("h264Format:\(status)") }
        let dimensions = CMVideoFormatDescriptionGetDimensions(parsed)
        guard width > 0, height > 0, dimensions.width >= width, dimensions.height >= height else {
            throw SceneValidator.invalid("videoSPSBounds")
        }
        guard dimensions.width <= 16_384, dimensions.height <= 16_384,
              UInt128(dimensions.width) * UInt128(dimensions.height) <= 16_777_216 else {
            throw PAGError.resourceLimitExceeded("videoDimensions")
        }
        guard var extensions = CMFormatDescriptionGetExtensions(parsed) as? [String: Any] else {
            throw PAGError.mediaFailure("h264FormatExtensions")
        }
        if let matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] {
            guard matrix as? String == kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 as String else {
                throw PAGError.unsupportedFeature("embeddedVideoColorMatrix")
            }
        }
        if let fullRange = extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] {
            guard let value = fullRange as? NSNumber, !value.boolValue else {
                throw PAGError.unsupportedFeature("embeddedVideoFullRange")
            }
        }
        if let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] {
            guard transfer as? String == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String else {
                throw PAGError.unsupportedFeature("embeddedVideoTransferFunction")
            }
        }
        // 真实探针证明SPS工厂描述可能被VT按尺寸猜成709；保留压缩配置，重建明确的601输入格式。
        extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] = kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] = false
        var explicit: CMVideoFormatDescription?
        let explicitStatus = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264,
            width: dimensions.width, height: dimensions.height, extensions: extensions as CFDictionary,
            formatDescriptionOut: &explicit)
        guard explicitStatus == noErr, let explicit else { throw PAGError.mediaFailure("h264ExplicitFormat:\(explicitStatus)") }
        try Task.checkCancellation()
        description = explicit
        size = try PAGSize(width: Double(dimensions.width), height: Double(dimensions.height))
    }

    /// 仅返回可发送的尺寸验证结果；临时系统描述在当前后台解码域释放。
    static func inspect(sps: Data, pps: Data, width: Int, height: Int) throws -> PAGSize {
        try H264Format(sps: sps, pps: pps, width: width, height: height).size
    }

    /// 构造持有压缩字节副本的AVCC样本；只复制NAL，不触碰解码像素，原始Data可立即释放。
    func makeSample(_ sample: SourceVideoSample, decodeIndex: Int, frameRate: Double) throws -> CMSampleBuffer {
        try Task.checkCancellation()
        guard !sample.data.isEmpty, let length = UInt32(exactly: sample.data.count), decodeIndex >= 0 else {
            throw PAGError.mediaFailure("h264SampleLength")
        }
        let byteCount = sample.data.count + 4
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw PAGError.mediaFailure("h264BlockBuffer:\(status)") }
        var prefix = length.bigEndian
        status = try withUnsafeBytes(of: &prefix) {
            guard let bytes = $0.baseAddress else { throw PAGError.mediaFailure("h264PrefixStorage") }
            return CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: 4)
        }
        guard status == noErr else { throw PAGError.mediaFailure("h264LengthPrefix:\(status)") }
        status = try sample.data.withUnsafeBytes {
            guard let bytes = $0.baseAddress else { throw PAGError.mediaFailure("h264SampleStorage") }
            return CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: 4, dataLength: sample.data.count)
        }
        guard status == noErr else { throw PAGError.mediaFailure("h264SampleBytes:\(status)") }
        // FrameToTime使用ceil；PTS与DTS分别转换，不能以编码索引覆盖重排后的显示时间。
        let pts = try SceneValidator.time(frame: sample.frame, rate: frameRate)
        let dts = try SceneValidator.time(frame: Int64(decodeIndex), rate: frameRate)
        let duration = try SceneValidator.time(frame: 1, rate: frameRate)
        var timing = CMSampleTimingInfo(duration: CMTime(value: duration.microseconds, timescale: 1_000_000),
            presentationTimeStamp: CMTime(value: pts.microseconds, timescale: 1_000_000),
            decodeTimeStamp: CMTime(value: dts.microseconds, timescale: 1_000_000))
        var size = byteCount
        var result: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: description,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &result)
        guard status == noErr, let result else { throw PAGError.mediaFailure("h264SampleBuffer:\(status)") }
        try Task.checkCancellation()
        return result
    }
}
