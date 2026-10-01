import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import VideoToolbox

/// 媒体owner域内的H.264输入；物理设备要求硬解，模拟器使用系统可用解码器，不生成RGBA或显示附件。
final class H264Session {
    /// 系统压缩格式留在当前同步owner域内。
    private let format: H264Format
    /// 唯一允许取消回调访问的有锁会话桥，不暴露VT对象。
    let lifetime: VideoSessionLifetime
    /// 系统报告是否实际硬解；查询失败为nil，仅模拟器允许false/nil，不作为物理设备性能证据。
    let usesHardwareDecoder: Bool?

    /// 生产平台强制硬解；开发模拟器没有同等硬件会话能力，只验证共同媒体/显示通路。
    private static var requiresHardware: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    /// 创建明确601的420v会话；仅模拟器允许系统软件解码，其他平台硬解不可用则失败。
    init(sequence: SourceVideoSequence, cleanup: DispatchQueue,
         willWaitForDecode: (@Sendable () -> Void)? = nil, willInvalidate: (@Sendable () -> Void)? = nil) throws {
        let format = try H264Format(sps: sequence.sps, pps: sequence.pps,
                                    width: sequence.videoWidth, height: sequence.videoHeight)
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        // 模拟器实测RequireHardware报-12906；编译期例外不能降低真机和macOS的硬解要求。
        let key = Self.requiresHardware ? kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder
            : kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder
        let specification: [CFString: Any] = [key: true]
        var raw: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format.description,
            decoderSpecification: specification as CFDictionary, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &raw)
        guard status == noErr, let raw else {
            if let raw { VTDecompressionSessionInvalidate(raw) }
            throw PAGError.mediaFailure("h264Session:\(status)")
        }
        let lifetime = VideoSessionLifetime(session: raw, cleanup: cleanup,
            willWaitForDecode: willWaitForDecode, willInvalidate: willInvalidate)
        var value: Unmanaged<CFTypeRef>?
        let queried = VTSessionCopyProperty(raw, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                            allocator: nil, valueOut: &value)
        // SDK的void*输出拥有一次retain；必须显式接管，不能通过AnyObject?隐式桥接。
        let hardware = value?.takeRetainedValue()
        let usesHardware = queried == noErr ? (hardware as? NSNumber)?.boolValue : nil
        guard !Self.requiresHardware || usesHardware == true else {
            lifetime.closeAndDrain()
            throw PAGError.mediaFailure("h264HardwareDecoderRequired")
        }
        self.format = format
        self.lifetime = lifetime
        usesHardwareDecoder = usesHardware
    }

    /// 最后释放可能发生在任意线程，仅投递关闭；不在析构中等待VT或进入MainActor。
    deinit { lifetime.close() }

    /// 解一个编码样本并验证实际输出；取消优先于系统失效错误，不发布已取消的缓冲。
    func decode(_ source: SourceVideoSample, index: Int, sequence: SourceVideoSequence,
                didOutput: (@Sendable () -> Void)? = nil) throws -> VideoDecodedFrame {
        let sample = try format.makeSample(source, decodeIndex: index, frameRate: sequence.frameRate)
        let slot = H264OutputSlot()
        defer { slot.discard() }
        let status = try lifetime.decode(sample, into: slot, didOutput: didOutput)
        try Task.checkCancellation()
        guard status == noErr else { throw PAGError.mediaFailure("h264Decode:\(status)") }
        guard let output = slot.take() else { throw PAGError.mediaFailure("h264MissingOutput") }
        guard output.status == noErr, let buffer = output.buffer else {
            throw PAGError.mediaFailure("h264Output:\(output.status)")
        }
        guard CMTimeCompare(output.time, CMSampleBufferGetPresentationTimeStamp(sample)) == 0 else {
            throw PAGError.mediaFailure("h264OutputTime")
        }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) == 2,
              CVPixelBufferGetWidth(buffer) == Int(format.size.width),
              CVPixelBufferGetHeight(buffer) == Int(format.size.height) else {
            throw PAGError.mediaFailure("h264OutputLayout")
        }
        let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil)
        guard matrix as? String == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String else {
            throw PAGError.mediaFailure("h264OutputColorMatrix")
        }
        // 只查询布局元数据，不锁定像素地址；实际stride成本可能大于可见宽高的NV12下界。
        let planes = (0..<2).reduce(0) { $0 + CVPixelBufferGetBytesPerRowOfPlane(buffer, $1) * CVPixelBufferGetHeightOfPlane(buffer, $1) }
        let bytes = max(planes, CVPixelBufferGetDataSize(buffer))
        guard bytes > 0 else { throw PAGError.mediaFailure("h264OutputStorage") }
        try Task.checkCancellation()
        return VideoDecodedFrame(frame: source.frame, buffer: buffer, byteCount: bytes)
    }
}

/// 系统回调局部桥；仅ARC保活只读输出，所有状态由短锁保护，不授予缓冲修改权。
final class H264OutputSlot: @unchecked Sendable {
    /// 回调借来的系统对象不能满足Mutex的sending转移要求，使用显式同步的局部桥。
    private let lock = NSLock()
    /// 首个完成值，尚未完成或已消费时为nil。
    private var output: H264Output?
    /// 一次性关闭门禁，拒绝重复或消费之后的迟到回调。
    private var closed = false

    /// 发布首个系统完成值；重复或迟到输出立即释放，锁内不进行解码和纹理导入。
    func publish(status: OSStatus, buffer: CVPixelBuffer?, time: CMTime) {
        lock.withLock {
            guard !closed, output == nil else { return }
            output = H264Output(status: status, buffer: buffer, time: time)
        }
    }

    /// 同步decode返回后消费一次；返回对象仅供当前owner同步作用域使用。
    func take() -> H264Output? {
        lock.withLock {
            closed = true
            let result = output
            output = nil
            return result
        }
    }

    /// 失败或取消时关闭并释放输出，之后的回调不得恢复已废弃的槽。
    func discard() {
        lock.withLock {
            closed = true
            output = nil
        }
    }
}

/// 回调槽的非Sendable完成值，不进入场景图或跨actor返回。
struct H264Output {
    /// 系统解码完成码，只有noErr且buffer非nil才有可用帧。
    let status: OSStatus
    /// 系统仍可能持有的只读图像，禁止修改像素或附件。
    let buffer: CVPixelBuffer?
    /// 实际回传PTS，与当前输入样本核对后才接受。
    let time: CMTime
}

/// 媒体owner持有的不可变输入帧；通过独立有锁槽才能移交给渲染owner。
struct VideoDecodedFrame {
    /// 实际显示帧号，不是编码索引或请求时间。
    let frame: Int64
    /// 完成解码后的只读系统帧，不直接遵循Sendable。
    let buffer: CVPixelBuffer
    /// 实际平面和总存储成本的较大值，供保留预算检查。
    let byteCount: Int
}
