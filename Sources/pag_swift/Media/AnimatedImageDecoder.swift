import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 动图编码快照和累计帧边界；不预解完整序列，也不持有可变ImageIO对象。
final class AnimatedImageStorage: Sendable {
    /// 完整编码内容身份，跨快照共享时不能只用URL或文件名。
    let identity: DocumentIdentity
    /// 首帧以外仍需按需解码的不可变编码字节。
    let data: Data
    /// ImageIO已识别的GIF或WebP格式标识。
    let sourceType: String
    /// 每帧结束的严格递增微秒边界，末项是一轮时长。
    let ends: [Int64]
    /// 一轮所有帧的总时长，必须正且不溢出。
    let durationMicroseconds: Int64
    /// nil表示无限循环，否则是至少一次的总播放次数。
    let playCount: Int?
    /// 全画布正尺寸；解码帧尺寸改变时拒绝发布。
    let size: PAGSize
    /// 宿主可选逐帧源；存在时 data 为空，帧合成由宿主 decoder 保证。
    let externalSource: (any PAGAnimatedImageSource)?

    /// 只接收已完整核对的时间表和编码快照。
    init(identity: DocumentIdentity, data: Data, sourceType: String, ends: [Int64],
         playCount: Int?, size: PAGSize, externalSource: (any PAGAnimatedImageSource)? = nil) throws {
        guard let duration = ends.last, duration > 0 else {
            throw PAGError.unsupportedAnimatedImage(sourceType)
        }
        self.identity = identity
        self.data = data
        self.sourceType = sourceType
        self.ends = ends
        durationMicroseconds = duration
        self.playCount = playCount
        self.size = size
        self.externalSource = externalSource
    }

    /// 用调用方提供的独立素材进度二分选帧；有限循环结束后保持最后一帧。
    func frameIndex(at time: PAGTime) -> Int {
        let value = max(0, time.microseconds)
        if let playCount, value / durationMicroseconds >= playCount { return ends.count - 1 }
        let position = value % durationMicroseconds
        var low = 0, high = ends.count
        while low < high {
            let middle = low + (high - low) / 2
            if position < ends[middle] { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// 从原文件内容身份和真实帧号导出独立纹理键，避免旧帧被GPU缓存当成新帧。
    func identity(for index: Int) throws -> DocumentIdentity {
        var bytes = Data(identity.digest)
        bytes.append(contentsOf: "pag.animated.frame".utf8)
        var value = UInt64(index).littleEndian
        withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        return try DocumentIdentity(data: bytes)
    }
}

/// 只用系统ImageIO验证GIF/WebP多帧时间与完整画布，实际帧在媒体owner中按需解码。
enum AnimatedImageDecoder {
    /// 单帧返回nil交给静图路径；多帧必须有完整有效元数据才发布PAGImage。
    static func decodeIfAnimated(_ data: Data, identity: DocumentIdentity,
                                 maximumDecodedBytes: Int) throws -> PAGImage? {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary),
            let rawType = CGImageSourceGetType(source) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        let type = rawType as String
        guard type == UTType.gif.identifier || type == UTType.webP.identifier else {
            throw PAGError.unsupportedAnimatedImage(type)
        }
        guard count <= 8_192, count <= maximumDecodedBytes / 32 else {
            throw PAGError.resourceLimitExceeded("maximumAnimatedFrames")
        }
        let dictionaryKey = type == UTType.gif.identifier ? kCGImagePropertyGIFDictionary :
            kCGImagePropertyWebPDictionary
        let loopKey = type == UTType.gif.identifier ? kCGImagePropertyGIFLoopCount :
            kCGImagePropertyWebPLoopCount
        guard let properties = CGImageSourceCopyProperties(source, nil) as? [String: Any],
              let animation = properties[dictionaryKey as String] as? [String: Any] else {
            throw PAGError.unsupportedAnimatedImage(type)
        }
        let rawLoop = (animation[loopKey as String] as? NSNumber)?.intValue ?? 1
        guard rawLoop >= 0, rawLoop < Int.max else { throw PAGError.unsupportedAnimatedImage(type) }
        // ImageIO把GIF的Netscape重复数归一为总播放次数；无扩展为1，显式0仍为无限。
        let plays: Int? = rawLoop == 0 ? nil : rawLoop
        var ends: [Int64] = []
        ends.reserveCapacity(count)
        var total: Int64 = 0
        var canvas: (width: Int, height: Int)?
        for index in 0..<count {
            try Task.checkCancellation()
            guard let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
                  let group = frame[dictionaryKey as String] as? [String: Any],
                  let width = (frame[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
                  let height = (frame[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
                  width > 0, height > 0 else {
                throw PAGError.unsupportedAnimatedImage(type)
            }
            if let canvas {
                // 局部补丁帧不能冒充完整画布；此子范围只接受ImageIO给出的全尺寸帧。
                guard width == canvas.width, height == canvas.height else {
                    throw PAGError.unsupportedAnimatedImage(type)
                }
            } else { canvas = (width, height) }
            let unclamped = type == UTType.gif.identifier ? kCGImagePropertyGIFUnclampedDelayTime :
                kCGImagePropertyWebPUnclampedDelayTime
            let clamped = type == UTType.gif.identifier ? kCGImagePropertyGIFDelayTime :
                kCGImagePropertyWebPDelayTime
            let seconds = positiveSeconds(group[unclamped as String]) ??
                positiveSeconds(group[clamped as String]) ?? 0.1
            let microseconds = (seconds * 1_000_000).rounded()
            guard microseconds.isFinite, microseconds > 0,
                  microseconds < Double(Int64.max),
                  let delay = Int64(exactly: microseconds) else {
                throw PAGError.unsupportedAnimatedImage(type)
            }
            let sum = total.addingReportingOverflow(delay)
            guard !sum.overflow else { throw PAGError.resourceLimitExceeded("animatedDuration") }
            total = sum.partialValue
            ends.append(total)
        }
        let poster = try StillImageDecoder.decodeFrame(data, index: 0, identity: identity,
            maximumDecodedBytes: maximumDecodedBytes)
        let metadata = try AnimatedImageStorage(identity: identity, data: data, sourceType: type,
            ends: ends, playCount: plays, size: poster.size)
        return PAGImage(storage: poster, animation: metadata)
    }

    /// 只接受有限正秒数，缺失或损坏字段交给下一候选及100ms缺省。
    private static func positiveSeconds(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite,
              number.doubleValue > 0 else { return nil }
        return number.doubleValue
    }
}
