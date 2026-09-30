import CoreMedia
import Dispatch
import Foundation
import Testing
import VideoToolbox
@testable import pag_swift

/// 会话取消令牌和已完成系统帧的迟到丢弃；使用真实硬件会话与可控暂停点，不靠睡眠竞速。
@Suite(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264), "需要H.264硬件解码"),
       .serialized, .timeLimit(.minutes(1)))
struct VideoCancellationTests {
    /// 已完成的旧请求失去取消权；活跃请求只关闭一次，排队前取消也不能漏过会话注册。
    @MainActor @Test func finishedRequestCannotCloseReusedSession() async throws {
        let source = try #require(await PAGVideoFixtures.compositions(in: "RootLayerVideo.pag").first?.video.sequences.last)
        let owner = VideoCancellationTestOwner()
        let lifetime = try await owner.create(source)
        let old = VideoDecodeRequest()
        try old.install(lifetime)
        old.finish()
        let current = VideoDecodeRequest()
        try current.install(lifetime)
        old.cancel()
        #expect(lifetime.isOpen)
        current.cancel()
        current.cancel()
        #expect(!lifetime.isOpen)
        await owner.drain()
        current.finish()
        let next = try await owner.create(source)
        let waiting = VideoDecodeRequest()
        waiting.cancel()
        #expect(throws: CancellationError.self) { try waiting.install(next) }
        #expect(!next.isOpen)
        await owner.drain()
    }

    /// 真实VT回调尚未返回时取消，独立清理仍启动；旧输出不发布，下一请求从新会话恢复。
    @MainActor @Test func cancellationDiscardsOutputBeforePublication() async throws {
        let source = try #require(await PAGVideoFixtures.compositions(in: "RootLayerVideo.pag").first?.video.sequences.last)
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (closings, closingContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = VideoFrameStore(onEvent: { event in
            switch event {
            case .output(index: 1):
                continuation.yield(())
                // 在真实VT回调内暂停，主actor和会话清理队列都必须保持可运行。
                release.wait()
            case .invalidating:
                closingContinuation.yield(())
            default:
                break
            }
        })
        let task = Task {
            defer {
                continuation.finish()
                closingContinuation.finish()
            }
            return try await store.frame(for: source, at: 1)
        }
        var iterator = events.makeAsyncIterator()
        _ = try #require(await iterator.next())
        task.cancel()
        var closingIterator = closings.makeAsyncIterator()
        _ = try #require(await closingIterator.next())
        release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await store.retainedBytes() == 0)
        #expect(await store.retainedSequenceCount() == 0)
        #expect(await store.decodedSampleCount == 2)
        let recovered = try await store.frame(for: source, at: 0)
        #expect(recovered.identity.frame == 0)
        #expect(await store.decodedSampleCount == 3)
    }
}

/// 测试独占的后台会话容器，让MainActor只接触有锁令牌，从不同步创建/关闭VT。
private actor VideoCancellationTestOwner {
    /// 系统创建与排空在独立串行执行器运行。
    nonisolated private let executor = DispatchSerialQueue(label: "pag.video.cancel.test")
    /// 真实actor executor与媒体实现的隔离边界一致。
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    /// 可以在媒体执行器暂停时仍运行的清理队列。
    private let cleanup = DispatchQueue(label: "pag.video.cancel.test.cleanup")
    /// 当前测试会话；替换前必须排空旧会话。
    private var session: H264Session?

    /// 建立真实硬件会话，只把有锁生命周期桥返回测试。
    func create(_ source: SourceVideoSequence) throws -> VideoSessionLifetime {
        #expect(!Thread.isMainThread)
        session?.lifetime.closeAndDrain()
        let created = try H264Session(sequence: source, cleanup: cleanup)
        #if !targetEnvironment(simulator)
        #expect(created.usesHardwareDecoder == true)
        #endif
        session = created
        return created.lifetime
    }

    /// 等待本次系统关闭真正完成，调用方的主actor通过await让出执行权。
    func drain() { session?.lifetime.closeAndDrain() }
}
