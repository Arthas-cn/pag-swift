import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import Metal
import Testing
import VideoToolbox
@testable import pag_swift

/// 原始PAG H.264输入到硬解NV12与Metal平面的系统闭包；尚不代表shader或可见播放验收。
@Suite(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) && MTLCreateSystemDefaultDevice() != nil,
                 "需要可访问的H.264硬件解码器与Metal设备"), .serialized, .timeLimit(.minutes(1)))
struct VideoToolboxInputTests {
    /// 52条真实序列各解前10帧，明确硬解、非主线程、BT.601/420v、PTS保持和两平面纹理导入。
    @MainActor @Test func decodesEveryRealSequenceIntoMetalCompatiblePlanes() async throws {
        let sequences = try await PAGVideoFixtures.allSequences()
        let count = try await VideoInputTestOwner().decode(sequences)
        #expect(count == 520)
    }
}

/// 测试使用与生产媒体owner相同的专用串行执行边界；裸系统对象从不作为actor结果返回。
private actor VideoInputTestOwner {
    /// 硬解同步调用只占用此测试专用队列。
    nonisolated private let executor = DispatchSerialQueue(label: "pag.video.input.test")
    /// actor所有隔离工作实际运行于该队列。
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    /// 逐序列创建和关闭会话，返回完成数量；不锁定像素地址、不创建最终显示附件。
    func decode(_ sequences: [SourceVideoSequence]) throws -> Int {
        #expect(Thread.isMainThread == false)
        dispatchPrecondition(condition: .onQueue(executor))
        let device = try #require(MTLCreateSystemDefaultDevice())
        var rawCache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &rawCache)
        #expect(status == kCVReturnSuccess)
        let cache = try #require(rawCache)
        var count = 0
        for sequence in sequences {
            try Task.checkCancellation()
            let format = try H264Format(sps: sequence.sps, pps: sequence.pps,
                                        width: sequence.videoWidth, height: sequence.videoHeight)
            let session = try makeSession(format)
            defer { VTDecompressionSessionInvalidate(session) }
            for (index, source) in sequence.samples.prefix(10).enumerated() {
                let sample = try format.makeSample(source, decodeIndex: index, frameRate: sequence.frameRate)
                let slot = H264OutputSlot()
                let decoded = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
                    status, _, buffer, pts, _ in slot.publish(status: status, buffer: buffer, time: pts)
                }
                #expect(decoded == noErr)
                let output = try #require(slot.take())
                #expect(output.status == noErr)
                #expect(CMTimeCompare(output.time, CMSampleBufferGetPresentationTimeStamp(sample)) == 0)
                let buffer = try #require(output.buffer)
                #expect(slot.take() == nil)
                try verify(buffer, sequence: sequence, cache: cache)
                count += 1
            }
        }
        return count
    }

    /// 要求硬件420v，保留IOSurface与Metal兼容；硬件属性必须实际为true而非只相信请求值。
    private func makeSession(_ format: H264Format) throws -> VTDecompressionSession {
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        let specification: [CFString: Any] = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
        var raw: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(allocator: nil, formatDescription: format.description,
            decoderSpecification: specification as CFDictionary, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &raw)
        #expect(created == noErr)
        let session = try #require(raw)
        var value: Unmanaged<CFTypeRef>?
        let result = VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                           allocator: nil, valueOut: &value)
        // SDK声明为void*，返回对象由调用方release；显式Unmanaged接收，不把AnyObject?隐式转指针。
        let hardware = value?.takeRetainedValue()
        #expect(result == noErr && (hardware as? NSNumber)?.boolValue == true)
        return session
    }

    /// 只读取元数据并导入纹理，确认颜色与alpha区域在实际平面内，禁止通过CPU像素兜底。
    private func verify(_ buffer: CVPixelBuffer, sequence: SourceVideoSequence, cache: CVMetalTextureCache) throws {
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(CVPixelBufferGetPlaneCount(buffer) == 2)
        #expect(CVPixelBufferGetWidth(buffer) >= sequence.videoWidth)
        #expect(CVPixelBufferGetHeight(buffer) >= sequence.videoHeight)
        let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil)
        #expect(matrix as? String == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
        for plane in 0..<2 {
            var wrapper: CVMetalTexture?
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let pixelFormat: MTLPixelFormat = plane == 0 ? .r8Unorm : .rg8Unorm
            let result = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, pixelFormat,
                                                                  width, height, plane, &wrapper)
            #expect(result == kCVReturnSuccess)
            let retained = try #require(wrapper)
            let texture = try #require(CVMetalTextureGetTexture(retained))
            #expect(texture.width == width && texture.height == height && texture.pixelFormat == pixelFormat)
        }
    }
}
