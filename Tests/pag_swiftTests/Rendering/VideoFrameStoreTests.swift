import CoreMedia
import CoreVideo
import Foundation
import Metal
import Testing
import VideoToolbox
@testable import pag_swift

/// 真实硬解输入的顺序、seek、有界保留和单次交接；不以元数据检查冒充最终画面验收。
@Suite(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) && MTLCreateSystemDefaultDevice() != nil,
                 "需要H.264硬件解码与Metal"), .serialized, .timeLimit(.minutes(3)))
struct VideoFrameStoreTests {
    /// 所有52条真实序列逐逻辑帧采样，PTS空洞仍选后继；每个压缩样本仅送入VT一次。
    @MainActor @Test func decodesAllRealSamplesInPresentationOrder() async throws {
        let sources = try await PAGVideoFixtures.allSequences()
        let store = VideoFrameStore()
        var expected = 0
        for source in sources {
            for index in source.samples.indices {
                let frame = try await store.frame(for: source, at: Int64(index))
                #expect(frame.identity.frame == source.samples[source.sampleIndex(at: Int64(index))].frame)
                #expect(frame.identity.sequence == source.identity)
                #expect(frame.byteCount > 0)
                #expect(await store.retainedBytes() <= 64 * 1024 * 1024)
            }
            expected += source.samples.count
            #expect(await store.retainedSequenceCount() <= 4)
            #expect(await store.retainedBytes() <= 64 * 1024 * 1024)
        }
        #expect(await store.decodedSampleCount == expected)
    }

    /// 同帧命中不重解码；跨关键帧直达和倒退只解最近关键帧到目标的输入，不从头扫完整片。
    @Test func seeksFromNearestKeyframeAndKeepsOldTransfer() async throws {
        let source = try #require(await PAGVideoFixtures.compositions(in: "RootLayerVideo.pag").first?.video.sequences.last)
        let store = VideoFrameStore()
        let first = try await store.frame(for: source, at: 0)
        for target: Int64 in [0, 1, 60, 61, 130, 239, 59, 2] {
            let before = await store.decodedSampleCount
            let frame = try await store.frame(for: source, at: target)
            let after = await store.decodedSampleCount
            #expect(frame.identity.frame == target)
            let upper = source.sampleIndex(at: target) - source.keyframeIndex(before: target) + 1
            #expect(after - before <= upper)
            let same = try await store.frame(for: source, at: target)
            #expect(same.identity == frame.identity)
            #expect(await store.decodedSampleCount == after)
        }
        // 旧交接槽跨过多次seek仍保活原始输入；不通过CPU读取像素来验证保活。
        try await Self.consume(first, width: source.videoWidth, height: source.videoHeight)
    }

    /// 极小预算、非法帧和预取消都失败；已取消请求不会损坏之前的同帧缓存。
    @Test func rejectsBudgetInvalidTimeAndPreCancelledRequest() async throws {
        let source = try #require(await PAGVideoFixtures.compositions(in: "RootLayerVideo.pag").first?.video.sequences.last)
        let tiny = VideoFrameStore(maximumBytes: 1)
        await #expect(throws: PAGError.resourceLimitExceeded("maximumVideoFrameBytes")) {
            try await tiny.frame(for: source, at: 0)
        }
        #expect(await tiny.decodedSampleCount == 0)
        let store = VideoFrameStore()
        let first = try await store.frame(for: source, at: 0)
        for target in [-1, source.samples.count] {
            await #expect(throws: PAGError.invalidArgument("videoFrame")) { try await store.frame(for: source, at: Int64(target)) }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.frame(for: source, at: 1)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let repeated = try await store.frame(for: source, at: 0)
        #expect(repeated.identity == first.identity)
        #expect(await store.decodedSampleCount == 1)
    }

    /// 会话LRU最多保留四条，实际缓冲预算也能在条目数未满时淘汰；仍被交接槽保活的帧可继续使用。
    @Test func evictsByCountAndActualByteCost() async throws {
        let variants = try #require(await PAGVideoFixtures.compositions(in: "data_video.pag").first?.video.sequences)
        let root = try #require(await PAGVideoFixtures.compositions(in: "RootLayerVideo.pag").first?.video.sequences.last)
        let store = VideoFrameStore()
        var transfers: [VideoFrameTransfer] = []
        for source in variants { transfers.append(try await store.frame(for: source, at: 0)) }
        #expect(await store.retainedSequenceCount() == 4)
        let last = try await store.frame(for: root, at: 0)
        #expect(await store.retainedSequenceCount() == 4)
        let first = try #require(transfers.first)
        let expected = transfers.dropFirst().reduce(last.byteCount) { $0 + $1.byteCount }
        #expect(await store.retainedBytes() == expected)
        let constrained = VideoFrameStore(maximumBytes: last.byteCount)
        _ = try await constrained.frame(for: variants[0], at: 0)
        _ = try await constrained.frame(for: root, at: 0)
        #expect(await constrained.retainedBytes() == last.byteCount)
        #expect(await constrained.retainedSequenceCount() == 1)
        try await Self.consume(first, width: variants[0].videoWidth, height: variants[0].videoHeight)
    }

    /// 系统回调重复或迟到时只接受首个完成，关闭槽之后不能重新发布输出。
    @Test func callbackSlotIsSingleUse() {
        let slot = H264OutputSlot()
        slot.publish(status: 123, buffer: nil, time: .zero)
        slot.publish(status: 456, buffer: nil, time: .invalid)
        #expect(slot.take()?.status == 123)
        #expect(slot.take() == nil)
        slot.publish(status: 789, buffer: nil, time: .zero)
        #expect(slot.take() == nil)
        let cancelled = H264OutputSlot()
        cancelled.discard()
        cancelled.publish(status: 123, buffer: nil, time: .zero)
        #expect(cancelled.take() == nil)
    }

    /// 在后台作用域消费并导入两平面；重复消费必须失败，CVMetalTexture与缓冲同时保活。
    @concurrent private static func consume(_ frame: VideoFrameTransfer, width: Int, height: Int) async throws {
        try consumeSynchronously(frame, width: width, height: height)
    }

    /// 无暂停点的系统输入核对，仅从后台入口调用，裸资源不会通过async返回。
    private static func consumeSynchronously(_ frame: VideoFrameTransfer, width: Int, height: Int) throws {
        #expect(!Thread.isMainThread)
        let buffer = try frame.take()
        #expect(CVPixelBufferGetWidth(buffer) >= width && CVPixelBufferGetHeight(buffer) >= height)
        #expect(throws: PAGError.mediaFailure("videoFrameAlreadyConsumed")) { try frame.take() }
        let device = try #require(MTLCreateSystemDefaultDevice())
        var raw: CVMetalTextureCache?
        #expect(CVMetalTextureCacheCreate(nil, nil, device, nil, &raw) == kCVReturnSuccess)
        let cache = try #require(raw)
        for plane in 0..<2 {
            var wrapper: CVMetalTexture?
            #expect(CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil,
                plane == 0 ? .r8Unorm : .rg8Unorm, CVPixelBufferGetWidthOfPlane(buffer, plane),
                CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &wrapper) == kCVReturnSuccess)
            #expect(CVMetalTextureGetTexture(try #require(wrapper)) != nil)
        }
    }
}
